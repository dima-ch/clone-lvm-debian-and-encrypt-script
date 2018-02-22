#!/bin/bash
#set -o verbose
#set -x

VMDIR=/data/backup/server/vm
VMDISC="$VMDIR/server-`date +%Y-%m-%d`.vdi"

mkdir -p $VMDIR

echo $VMDISC

/sbin/rmmod nbd
/sbin/modprobe nbd max_part=16

/usr/bin/VBoxManage createhd --filename $VMDISC --size 100000

/usr/bin/qemu-nbd -c /dev/nbd0 $VMDISC

/root/clone-lvm-debian-and-encrypt-script/clone-lvm-debian-and-encrypt.sh /dev/nbd0 root1488755024 root \
 --force --snapshot-size 1G --root-size 95G  \
 --add-crypttab "#raid /dev/md0 /root/keyfile luks" \
 --add-fstab "#/dev/raid-vg/data /mnt/data ext4 errors=remount-ro,noatime,nodiratime 0 2" \
 --exclude-dirs "/var/data/"

/usr/bin/qemu-nbd -d /dev/nbd0
/sbin/pvscan --cache

