#!/bin/bash

# Клонируем запущенный линукс установленный на LVM на лету на другой носитель с шифрованием или без.
# Пригодится при переносе ситемы с одного жесткого диска на другой "на лету" не останавливая систему для загрузки с live-cd и прочей ерунды.
# При клонирование можно зашивровать новый носитель с системой при помощи cryptsetup (конечно-же кроме boot раздела).
# Размер нового носителя не ограничен размером томов клонируемой системы, а зависит от общего размера всех фалов клонируемой системы.

# Строка добавляемая в /etc/fstab на склонированной системе
# #FSTAB_ADD="/dev/raid-vg/data  /mnt/data ext4  errors=remount-ro,noatime,nodiratime 0    2"
# Строка добавляемая в /etc/crypttab на склонированной системе
# CRYPTTAB_ADD="raid /dev/md0 /root/keyfile luks"
#
# Если в группе (vg_name) нет места под снапшот рута можно указать другой диск для временного расширения группы томов --extend-dev /dev/..., 
# можно указать например --extend-dev /dev/ram0, но стоит учитывать, что по умолчанию это 16MB и может не хватить
# Если указан --extend-dev то размер снапшота (--snapshot-size) будет равен размеру диска для временного расширения

# TODO скрипт нуждается в проверках выполения действий!

function usage {
	echo "usage /dev/disk vg_name lv_name [--encrypt] [--snapshot-size size MB] [--no-rsync] [--extend-dev /dev/...] [--root-size size MB] [--swap-size size] [--new-hostname hostname]"
	echo "/dev/disk - диск на который будет клонироваться система, на нем будет создано 2 раздела: boot и остальное место под LVM"
	echo "vg_name - имя группы томов клонируемой системы"
	echo "lv_name - имя тома с рутом клонируемой системы"
	echo "Внимание! Клонируется только root и boot, скрипт не подойдет если var usr home и т.д. на отдельных разделах"
	exit 1
}

DISK=$1
OLD_ROOT_LV=$3
OLD_ROOT_VG=$2

SNAPSHOT_SIZE="200"
RSYNC_OPTIONS=" --one-file-system  -a " # -v --progress 



if [ ! -b "/dev/${OLD_ROOT_VG}/${OLD_ROOT_LV}" ] || [ ! -e "/dev/${OLD_ROOT_VG}/${OLD_ROOT_LV}" ]  || [ ! -n "$2" ]  || [ ! -n "$3" ]; then
	echo "ERROR: INCORRECT VG OR LV NAME (no device: /dev/${OLD_ROOT_VG}/${OLD_ROOT_LV})"
	usage
fi

if [ ! -b $DISK ] || [ ! -e $DISK ] || [ ! -n "$1" ]; then
	echo "ERROR: INCORRECT DISK PATH $DISK"
	usage
fi

shift
shift
shift

while [[ $# > 0 ]]
do
	key="$1"

	case $key in
		--encrypt)
ENCRYPT="TRUE"
echo "ENCRYPT"
;;
--no-rsync)
NORSYNC="TRUE"
echo "NORSYNC"
;;
--extend-dev)
if [  $# == 1 ]; then
	echo "MISSING EXTEND_DEVICE"
	usage
fi
EXTEND_DEVICE="$2"
echo "EXTEND_DEVICE $EXTEND_DEVICE"
shift
;;
--new-hostname)
if [  $# == 1 ]; then
	echo "MISSING NEW HOSTNAME"
	usage
fi
NEW_HOSTNAME="$2"
echo "NEW_HOSTNAME $NEW_HOSTNAME"
shift
;;
--snapshot-size)
if [  $# == 1 ]; then
	echo "MISSING SNAPSHOT_SIZE"
	usage
fi
SNAPSHOT_SIZE="$2"
echo "SNAPSHOT_SIZE $SNAPSHOT_SIZE"
shift
--root-size)
if [  $# == 1 ]; then
	echo "MISSING ROOT_SIZE"
	usage
fi
ROOT_SIZE="$2"
echo "ROOT_SIZE $ROOT_SIZE"
shift
;;
--swap-size)
if [  $# == 1 ]; then
	echo "MISSING SWAP_SIZE"
	usage
fi
SWAP_SIZE="$2"
echo "SWAP_SIZE $SWAP_SIZE"
shift
;;
*)
usage
;;
esac
shift
done

NEW_VG_NAME="root`date +%s`"

echo -e "========Warning!\nPlease disable automount (System-Settings - Details - Removable Media)"
read -p "Press any key to start"
echo "========create disk part table"
parted $DISK mktable msdos
#TODO: размер бута сделать настраевымым
parted -a optimal $DISK mkpart primary 2048sec 616447sec
parted -a optimal $DISK mkpart primary 616448sec 100%
sleep 1
if [ -e ${DISK}-part1 ]; then
	BOOT=${DISK}-part1
fi

if [ -e ${DISK}1 ]; then
	BOOT=${DISK}1
fi

if [ -e ${DISK}p1 ]; then
	BOOT=${DISK}p1
fi

if [ ! -n "$BOOT" ]; then
	echo "ERROR: PART 1 OF DISK NOT FOUND!"
	exit 1
fi

if [ -e ${DISK}-part2 ]; then
	NEW_LVM_PARTIRION=${DISK}-part2
fi

if [ -e ${DISK}2 ]; then
	NEW_LVM_PARTIRION=${DISK}2
fi

if [ -e ${DISK}p2 ]; then
	NEW_LVM_PARTIRION=${DISK}p2
fi

if [ ! -n "$NEW_LVM_PARTIRION" ]; then
	echo "ERROR: PART 2 OF DISK NOT FOUND!"
	exit 1
fi


if [ -n "$ENCRYPT" ]; then
	echo "========ecrypt"
	if [ ! -f /sbin/cryptsetup ]; then
    	echo "cryptsetup not found!"
    	exit 1
	fi
	
	/sbin/cryptsetup luksFormat $NEW_LVM_PARTIRION
	sleep 2
	CRYPTNAME="crypt${NEW_VG_NAME}"
	/sbin/cryptsetup luksOpen $NEW_LVM_PARTIRION $CRYPTNAME
	REAL_NEW_LVM_PARTIRION=$NEW_LVM_PARTIRION
	NEW_LVM_PARTIRION=/dev/mapper/$CRYPTNAME

fi

echo "========create lvm"
pvcreate $NEW_LVM_PARTIRION
vgcreate $NEW_VG_NAME $NEW_LVM_PARTIRION

if [ -n "$SWAP_SIZE" ]; then
	lvcreate $NEW_VG_NAME -n swap -L $SWAP_SIZE
	mkswap /dev/mapper/${NEW_VG_NAME}-swap
fi

if [ -n "$ROOT_SIZE" ]; then
	lvcreate $NEW_VG_NAME -n root -L $ROOT_SIZE
else
	lvcreate $NEW_VG_NAME -n root -l 100%FREE
fi
ROOTLVNAME="/dev/${NEW_VG_NAME}/root"
mkfs.ext4 -m 0 $ROOTLVNAME

#-----------------------------------
ROOTMNTTMP="/mnt/rootmnttmp"
OLD_ROOT_MNT_TMP="/mnt/old-root-mnt-tmp"

echo "========create old root lvm snapshot"
if [ -n "$EXTEND_DEVICE" ]; then
	/sbin/vgextend $OLD_ROOT_VG $EXTEND_DEVICE 
	vgreduce --removemissing $OLD_ROOT_VG
	SNAPSHOT_SIZE=$(( (`/sbin/blockdev --getsize64 $EXTEND_DEVICE`/1024)/1024 - 4 ))
fi

/sbin/lvcreate --snapshot -n root-snapshot -L ${SNAPSHOT_SIZE}M /dev/${OLD_ROOT_VG}/${OLD_ROOT_LV}
if [ $? != 0 ];then
	fLog "lvcreate snapshot failed";
	exit 1;
fi

echo "========mount old root snapshot"
mkdir $OLD_ROOT_MNT_TMP
mount -o ro /dev/$OLD_ROOT_VG/root-snapshot $OLD_ROOT_MNT_TMP
sleep 1


read -p "Press any key to mount new root" 
mkdir $ROOTMNTTMP
echo "========mount new root"
mount $ROOTLVNAME $ROOTMNTTMP

read -p "Press any key to rsync root" 
echo "========rsync root"
if [ ! -n "$NORSYNC" ]; then
	rsync $RSYNC_OPTIONS $OLD_ROOT_MNT_TMP/* $ROOTMNTTMP/
fi

echo "========umount old root snapshot"
umount $OLD_ROOT_MNT_TMP

echo "========remove old root lvm snapshot"
echo y | /sbin/lvremove /dev/$OLD_ROOT_VG/root-snapshot
if [ -n "$EXTEND_DEVICE" ]; then
	/sbin/vgreduce  $OLD_ROOT_VG $EXTEND_DEVICE
fi

echo "========mkfs new boot"
mkfs.ext2 -m 5 $BOOT
echo "========mount new boot"
mount $BOOT $ROOTMNTTMP/boot

read -p "Press any key to rsync boot" 
echo "========rsync boot"
if [ ! -n "$NORSYNC" ]; then
	rsync $RSYNC_OPTIONS  /boot/* $ROOTMNTTMP/boot
fi

echo "========update crypttab and fstab"
BOOT_UUID=`blkid $BOOT | awk '{split($2, a, "\"");  print a[2];}'`
rm $ROOTMNTTMP/etc/crypttab
if [ -n "$ENCRYPT" ]; then
	CRYPTDEVUUID=`blkid $REAL_NEW_LVM_PARTIRION | awk '{split($2, a, "\"");  print a[2];}'`
	echo $CRYPTNAME" UUID="$CRYPTDEVUUID" none luks,discard" > $ROOTMNTTMP/etc/crypttab
	if [ -n "$CRYPTTAB_ADD" ]; then
		echo $CRYPTTAB_ADD >> $ROOTMNTTMP/etc/crypttab
	fi
fi

echo "/dev/mapper/"$NEW_VG_NAME"-root   /               ext4    errors=remount-ro 0       1" > $ROOTMNTTMP/etc/fstab
echo "UUID="$BOOT_UUID"   /boot               ext2    defaults        0       2" >> $ROOTMNTTMP/etc/fstab
if [ -n "$SWAP_SIZE" ]; then
	echo "/dev/mapper/"$NAME"-swap   none            swap    sw              0       0" >> $ROOTMNTTMP/etc/fstab
fi
if [ -n "$FSTAB_ADD" ]; then
	echo $FSTAB_ADD >> $ROOTMNTTMP/etc/fstab
fi

echo "========mount dev proc sys"
mount -o bind /dev $ROOTMNTTMP/dev
mount -t proc none $ROOTMNTTMP/proc
mount -t sysfs none $ROOTMNTTMP/sys

echo "========install grub"
chroot $ROOTMNTTMP grub-install ${DISK}
echo "========update-initramfs"
chroot $ROOTMNTTMP update-initramfs -k all -c
echo "========udate grub"
chroot $ROOTMNTTMP update-grub ${DISK}

if [ -n "$NEW_HOSTNAME" ]; then
	OLD_HOSTNAME=$(cat /etc/hostname)
	echo "========change hostname"
	chroot $ROOTMNTTMP sed -i "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
	chroot $ROOTMNTTMP sed -i "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/hostname
fi

echo "========umount dev proc sys boot /"
sleep 5
umount $ROOTMNTTMP/dev
umount $ROOTMNTTMP/proc
umount $ROOTMNTTMP/sys
umount $ROOTMNTTMP/boot
umount $ROOTMNTTMP

sleep 5
vgchange -a n $NEW_VG_NAME

sleep 5
if [ -n "$ENCRYPT" ]; then
	/sbin/cryptsetup luksClose $CRYPTNAME
fi
