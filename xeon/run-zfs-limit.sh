set -e

LOG_DIR=$1

JOBS=8
CLIENTS=32
DURATION_RO=900
DURATION_RW=3600
RUNS_RO=1
RUNS_RW=1

DATADIR=/mnt/zfs_raid/pg/data

recordsize="8K"
compression="lz4"
atime="off"
relatime="on"
logbias="latency"
redundant_metadata="most"


for level in stripe; do

	for pgconf in default no-fpw-tuned; do

		if [ "$pgconf" == "default" ]; then
			rate=3000
		else
			rate=5000
		fi

		limit=$((2*1000*CLIENTS/rate))

		        TESTDIR=$LOG_DIR/$level/$pgconf

			if [ -d "$TESTDIR" ]; then
				echo "skipping $TESTDIR"
				continue
			fi

		        mkdir -p $TESTDIR

			CSV="$level;$pgconf"

			echo "===== $pgconf $level $rate $limit ====="

			l=$level
			if [ "$level" == "stripe" ]; then
				l=''
			fi

			# create the ZFS stuff

			sudo zpool create -f -o ashift=12 -R /mnt zfs_raid $l /dev/nvme0n1p1 > $TESTDIR/zpool.create.log 2>&1

			sudo zfs set recordsize=$recordsize compression=$compression atime=$atime relatime=$relatime logbias=$logbias redundant_metadata=$redundant_metadata zfs_raid > $TESTDIR/zfs.set.log 2>&1

			sudo zfs create zfs_raid/pg > $TESTDIR/zfs.create.log 2>&1

			sudo chown postgres:postgres /mnt/zfs_raid/pg

			sudo zfs get all zfs_raid/pg > $TESTDIR/zfs.log 2>&1

			sudo zpool status zfs_raid > $TESTDIR/zpool.status.log 2>&1



			pg_ctl -D $DATADIR init > $TESTDIR/initdb.log 2>&1

			cp postgresql-$pgconf.conf $DATADIR/postgresql.conf

			pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w start 2>&1

			ps ax > $TESTDIR/ps.log 2>&1

			pg_config > $TESTDIR/pg_config.log 2>&1

			psql postgres -c "select * from pg_settings" > $TESTDIR/settings.log 2>&1


			for scale in 10000; do

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

				echo "$t1;$t2;$CSV;$scale;init;$d;$w" >> $LOG_DIR/init.csv 2>&1

				t1=`date +%s`
				s=`psql -t -A test -c "select extract(epoch from now())"`
				w=`psql -t -A test -c "select pg_current_wal_lsn()"`
				vacuumdb --freeze --min-xid-age=1 test > $TESTDIR/$scale/vacuum.log 2>&1
				d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
				w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
				t2=`date +%s`

				echo "$t1;$t2;$CSV;$scale;vacuum;$d;$w" >> $LOG_DIR/init.csv 2>&1

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

					echo "$t1;$t2;$CSV;$scale;ro;$tps;$d;$w" >> $LOG_DIR/results.csv 2>&1

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
					pgbench -n -M prepared -N -R $rate -L $limit -j $JOBS -c $CLIENTS -T $DURATION_RW -l --sampling-rate=0.01 test > $TESTDIR/$scale/run-rw-$r/pgbench.log 2>&1

					tar -czf $TESTDIR/$scale/run-rw-$r/pgbench_log.tgz pgbench_log.*
					rm -f pgbench_log.*

					d=`psql -t -A test -c "select extract(epoch from now()) - $s"`
					w=`psql -t -A test -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$w')"`
					t2=`date +%s`

					tps=`cat $TESTDIR/$scale/run-rw-$r/pgbench.log | grep 'without initial' | awk '{print $3}'`

					echo "$t1;$t2;$CSV;$scale;rw;$tps;$d;$w" >> $LOG_DIR/results.csv 2>&1

					st=`psql -t -A test -c "select sum(pg_table_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
					si=`psql -t -A test -c "select sum(pg_indexes_size(oid)) from pg_class where relnamespace = 2200 and relkind = 'r'"`
					sd=`psql -t -A test -c "select pg_database_size('test')"`

					echo "after;$st;$si;$sd" >> $TESTDIR/$scale/run-rw-$r/sizes.csv 2>&1

					sudo zpool status zfs_raid >> $TESTDIR/$scale/run-rw-$r/zpool.status.log 2>&1

					sleep 60

				done

			done

			pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w -m immediate -t 3600 stop

			sudo zpool status zfs_raid >> $TESTDIR/zpool.log 2>&1

			sudo zpool destroy zfs_raid

	done

done
