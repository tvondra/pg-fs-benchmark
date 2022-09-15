#!/bin/bash -x

set -e

LOG_DIR=$1

JOBS=4
CLIENTS=16
DURATION_RO=900
DURATION_RW=1800
RUNS_RO=1
RUNS_RW=1

DATADIR=/mnt/zfs_raid/pg/data

rm -Rf params.txt

for atime in off on; do                         						# access time
	for xattr in sa on off; do								# extended attributes
		for rs in 8K 128K; do                           				# record size
			for meta in most all; do        					# redundant metadata
				for logbias in latency throughput; do				# logbias
					for compression in off lz4 zstd; do			# compression
						for level in stripe mirror raidz1 raidz2; do	# raid level
							echo $level $rs $atime $logbias $meta $compression $xattr >> params.txt
						done
					done
				done
			done
		done
	done
done



while read line; do

	IFS=" " read -a strarr <<< "$line"

	level="${strarr[0]}"
	rs="${strarr[1]}"
	atime="${strarr[2]}"
	logbias="${strarr[3]}"
	meta="${strarr[4]}"
	compression="${strarr[5]}"
	xattr="${strarr[6]}"

        TESTDIR=$LOG_DIR/$level/$rs/$compression/$logbias/$atime/$meta/$xattr
        mkdir -p $TESTDIR

	CSV="$level;$rs;$compression;$logbias;$atime;$meta;$xattr"

	echo "===== $level / recordsize $rs / atime $atime / logbias $logbias / redundant_metadata $meta / compression $compression / xattr $xattr ====="

	if [ "$level" == "stripe" ]; then
		level=''
	fi

	# create the ZFS stuff

	sudo zpool create -o ashift=12 -R /mnt zfs_raid $level /dev/sda /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf > $TESTDIR/zpool.create.log 2>&1

	sudo zfs set recordsize=$rs compression=$compression atime=$atime xattr=$xattr logbias=$logbias redundant_metadata=$meta zfs_raid > $TESTDIR/zfs.set.log 2>&1

	sudo zfs create zfs_raid/pg > $TESTDIR/zfs.create.log 2>&1

	sudo chown postgres:postgres /mnt/zfs_raid/pg

	sudo zfs get all zfs_raid/pg > $TESTDIR/zfs.log 2>&1

	sudo zpool status zfs_raid > $TESTDIR/zpool.status.log 2>&1



	pg_ctl -D $DATADIR init > $TESTDIR/initdb.log 2>&1

	cp postgresql.conf $DATADIR

	pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w start 2>&1

	ps ax > $TESTDIR/ps.log 2>&1

	pg_config > $TESTDIR/pg_config.log 2>&1

	psql postgres -c "select * from pg_settings" > $TESTDIR/settings.log 2>&1


	for scale in 50 250 1000; do

		dropdb --if-exists test
		createdb test

		mkdir $TESTDIR/$scale

		t1=`date +%s`
		s=`psql -t -A test -c "select extract(epoch from now())"`
		w=`psql -t -A test -c "select pg_current_wal_lsn()"`
		pgbench -i -s $scale test > $TESTDIR/$scale/init.log 2>&1
		d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
		w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
		t2=`date +%s`

		echo "$t1;$t2;$CSV;$scale;init;$d;$w" >> init.csv 2>&1

		t1=`date +%s`
		s=`psql -t -A test -c "select extract(epoch from now())"`
		w=`psql -t -A test -c "select pg_current_wal_lsn()"`
		vacuumdb --freeze --min-xid-age=1 test > $TESTDIR/$scale/vacuum.log 2>&1
		d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
		w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
		t2=`date +%s`

		echo "$t1;$t2;$CSV;$scale;vacuum;$d;$w" >> init.csv 2>&1

		# read-only runs

		for r in `seq -s ' ' 1 $RUNS_RO`; do

			# skip read-only on the small scale (fits into shared buffers)
			if [ "$scale" == "50" ]; then
				continue
			fi

			rm -f pgbench_log.*

			mkdir $TESTDIR/$scale/run-ro-$r

			sudo zpool status zfs_raid > $TESTDIR/$scale/run-ro-$r/zpool.status.log 2>&1

			t1=`date +%s`
			st=`psql -t -A test -c "select sum(pg_table_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			si=`psql -t -A test -c "select sum(pg_indexes_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			sd=`psql -t -A test -c "select pg_database_size('test')"`

			echo "before;$st;$si;$sd" > $TESTDIR/$scale/run-ro-$r/sizes.csv 2>&1

			c=`ps ax | grep collect-stats | grep -v grep | wc -l`
			if [ "$c" != "0" ]; then
				ps ax | grep collect-stats
				ps ax | grep collect-stats | awk '{print $1}' | xargs kill > /dev/null 2>&1
			fi

			./collect-stats.sh $DURATION_RO $TESTDIR/$scale/run-ro-$r &

			s=`psql -t -A test -c "select extract(epoch from now())"`
			w=`psql -t -A test -c "select pg_current_wal_lsn()"`

			# get sample of transactions from last run
			pgbench -n -M prepared -S -j $JOBS -c $CLIENTS -T $DURATION_RO -l --sampling-rate=0.01 test > $TESTDIR/$scale/run-ro-$r/pgbench.log 2>&1

			tar -czf $TESTDIR/$scale/run-ro-$r/pgbench_log.tgz pgbench_log.*
			rm -f pgbench_log.*

			d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
			w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
			t2=`date +%s`

			tps=`cat $TESTDIR/$scale/run-ro-$r/pgbench.log | grep 'without initial' | awk '{print $3}'`

			echo "$t1;$t2;$CSV;$scale;ro;$tps;$d;$w" >> results.csv 2>&1

			st=`psql -t -A test -c "select sum(pg_table_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			si=`psql -t -A test -c "select sum(pg_indexes_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			sd=`psql -t -A test -c "select pg_database_size('test')"`

			echo "after;$st;$si;$sd" >> $TESTDIR/$scale/run-ro-$r/sizes.csv 2>&1

			sudo zpool status zfs_raid >> $TESTDIR/$scale/run-ro-$r/zpool.status.log 2>&1

			sleep 60

		done

		# sync before the read-write phase
		psql test -c checkpoint > /dev/null 2>&1

			# read-write runs
			for r in `seq -s ' ' 1 $RUNS_RW`; do

			rm -f pgbench_log.*

			mkdir $TESTDIR/$scale/run-rw-$r

			sudo zpool status zfs_raid > $TESTDIR/$scale/run-rw-$r/zpool.status.log 2>&1

			t1=`date +%s`
			st=`psql -t -A test -c "select sum(pg_table_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			si=`psql -t -A test -c "select sum(pg_indexes_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			sd=`psql -t -A test -c "select pg_database_size('test')"`

			echo "before;$st;$si;$sd" > $TESTDIR/$scale/run-rw-$r/sizes.csv 2>&1

			c=`ps ax | grep collect-stats | grep -v grep | wc -l`
			if [ "$c" != "0" ]; then
				ps ax | grep collect-stats | awk '{print $1}' | xargs kill > /dev/null 2>&1
			fi

			./collect-stats.sh $DURATION_RW $TESTDIR/$scale/run-rw-$r &

			s=`psql -t -A test -c "select extract(epoch from now())"`
			w=`psql -t -A test -c "select pg_current_wal_lsn()"`

			# get sample of transactions from last run
			pgbench -n -M prepared -N -j $JOBS -c $CLIENTS -T $DURATION_RW -l --sampling-rate=0.01 test > $TESTDIR/$scale/run-rw-$r/pgbench.log 2>&1

			tar -czf $TESTDIR/$scale/run-rw-$r/pgbench_log.tgz pgbench_log.*
			rm -f pgbench_log.*

			d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
			w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
			t2=`date +%s`

			tps=`cat $TESTDIR/$scale/run-rw-$r/pgbench.log | grep 'without initial' | awk '{print $3}'`

			echo "$t1;$t2;$CSV;$scale;rw;$tps;$d;$w" >> results.csv 2>&1

			st=`psql -t -A test -c "select sum(pg_table_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			si=`psql -t -A test -c "select sum(pg_indexes_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
			sd=`psql -t -A test -c "select pg_database_size('test')"`

			echo "after;$st;$si;$sd" >> $TESTDIR/$scale/run-rw-$r/sizes.csv 2>&1

			sudo zpool status zfs_raid >> $TESTDIR/$scale/run-rw-$r/zpool.status.log 2>&1

			sleep 60

		done

	done

	pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w stop

	sudo zpool status zfs_raid >> $TESTDIR/zpool.log 2>&1

	sudo zpool destroy zfs_raid

done < params.txt
