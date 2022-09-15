#!/bin/bash -x

set -e

LOG_DIR=$1

JOBS=8
CLIENTS=32
DURATION_RO=900
DURATION_RW=3600
RUNS_RO=1
RUNS_RW=1

MOUNTDIR=/mnt/data
DATADIR=$MOUNTDIR/pgdata


# for level in 0 1 10 5 6; do
# for level in 1 10 5 6; do
for level in 0; do

	pgconf='default'

	for fs in xfs ext4; do

		        TESTDIR=$LOG_DIR/$level/$fs

			if [ -d "$TESTDIR" ]; then
				echo "skipping $TESTDIR"
				continue
			fi

		        mkdir -p $TESTDIR

			rate=10000
			limit=$((2000*32/rate))

			CSV="$level;$pgconf;$fs"

			echo "===== $pgconf $level $fs $rate $limit ====="

			# create filesystem stuff

			if [ "$fs" == "ext4" ]; then
				sudo mkfs.ext4 -F /dev/nvme0n1p1
			else
				sudo mkfs.xfs -f /dev/nvme0n1p1
			fi

			sleep 5

			sudo mount -o relatime /dev/nvme0n1p1 /mnt/data > $TESTDIR/fs.mount.log 2>&1

			sudo chown postgres:postgres /mnt/data > $TESTDIR/fs.chown.log 2>&1


			pg_ctl -D $DATADIR init > $TESTDIR/initdb.log 2>&1

			cp postgresql-$pgconf.conf $DATADIR/postgresql.conf

			pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w start 2>&1

			ps ax > $TESTDIR/ps.log 2>&1

			pg_config > $TESTDIR/pg_config.log 2>&1

			psql postgres -c "select * from pg_settings" > $TESTDIR/settings.log 2>&1

			cat /proc/mdstat > $TESTDIR/mdstat.log 2>&1

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

					# sudo btrfs filesystem show > $TESTDIR/$scale/run-ro-$r/btrfs.fs.show.log 2>&1
					# sudo btrfs filesystem df $MOUNTDIR > $TESTDIR/$scale/run-ro-$r/btrfs.fs.df.log 2>&1
					# sudo btrfs filesystem usage $MOUNTDIR > $TESTDIR/$scale/run-ro-$r/btrfs.fs.usage.log 2>&1

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

					# sudo btrfs filesystem show >> $TESTDIR/$scale/run-ro-$r/btrfs.fs.show.log 2>&1
					# sudo btrfs filesystem df $MOUNTDIR >> $TESTDIR/$scale/run-ro-$r/btrfs.fs.df.log 2>&1
					# sudo btrfs filesystem usage $MOUNTDIR >> $TESTDIR/$scale/run-ro-$r/btrfs.fs.usage.log 2>&1

					sleep 60

				done

				# sync before the read-write phase
				psql test -c checkpoint > /dev/null 2>&1

					# read-write runs
					for r in `seq -s ' ' 1 $RUNS_RW`; do

					rm -f pgbench_log.*

					mkdir $TESTDIR/$scale/run-rw-$r

					# sudo btrfs filesystem show > $TESTDIR/$scale/run-rw-$r/btrfs.fs.show.log 2>&1
					# sudo btrfs filesystem df $MOUNTDIR > $TESTDIR/$scale/run-rw-$r/btrfs.fs.df.log 2>&1
					# sudo btrfs filesystem usage $MOUNTDIR > $TESTDIR/$scale/run-rw-$r/btrfs.fs.usage.log 2>&1

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
					pgbench -n -M prepared -R $rate -L $limit -N -j $JOBS -c $CLIENTS -T $DURATION_RW -l --sampling-rate=0.01 test > $TESTDIR/$scale/run-rw-$r/pgbench.log 2>&1

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

					# sudo btrfs filesystem show >> $TESTDIR/$scale/run-rw-$r/btrfs.fs.show.log 2>&1
					# sudo btrfs filesystem df $MOUNTDIR >> $TESTDIR/$scale/run-rw-$r/btrfs.fs.df.log 2>&1
					# sudo btrfs filesystem usage $MOUNTDIR >> $TESTDIR/$scale/run-rw-$r/btrfs.fs.usage.log 2>&1

					sleep 60

				done

			done

			pg_ctl -D $DATADIR -l $TESTDIR/pg.log -w -m immediate -t 3600 stop

			sudo umount /mnt/data

	done

done
