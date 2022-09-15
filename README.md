# pgbench on Linux file systems

Results for pgbench on different filesystems, from two different machines.

## i5

* CPU: i5-2500K
* RAM: 8GB RAM
* storage: 6 x 100GB Intel S3700 SSD (SATA)
* kernel 5.17.11

### Results

* `20220903-zfs` - ZFS with different RAID layouts and pg configs
* `20220906-btrfs` - BTRFS with different RAID layouts
* `20220907-mdraid` - EXT4/XFS with RAID0
* `20220907-mdraid-2` - EXT4/XFS with RAID1 and RAID10
* `20220908-mdraid-3` - EXT4/XFS with RAID5 and RAID6
* `20220909-zfs-raid10` - ZFS with RAID10 layout
* `20220909-zfs-large` - ZFS with scale 5000
* `20220911-mdraid-large` - EXT4/XFS with scale 5000
* `20220912-btrfs-large` - BTRFS with scale 5000
* `20220912-zfs-limit` - ZFS with `pgbench -R` limit
* `20220912-btrfs-limit` - BTRFS with `pgbench -R` limit
* `20220913-mdraid-limit` - EXT4/XFS with `pgbench -R` limit
* `20220913-mdraid-limit-2` - EXT4/XFS with `pgbench -R` limit


## xeon

* CPU: 2x e5-2620v3
* RAM: 64GB
* storage: 1 x WD Gold SSD 960GB (NVMe)
* kernel 5.17.11

### Results

* `20220909-zfs` - ZFS with different pg configs
* `20220910-btrfs` - BTRFS results
* `20220910-zfs` - ZFS with correct scales (20220909 used those from i5)
* `20220911-xfs-ext4` - EXT4/XFS results
* `20220912-btrfs-limit` - BTRFS with `pgbench -R` limit
* `20220912-mdraid-limit` - EXT4/XFS with `pgbench -R` limit
* `20220912-zfs-limit` - ZFS with `pgbench -R` limit
* `20220913-mdraid-limit` - EXT4/XFS with `pgbench -R` limit (different one)
