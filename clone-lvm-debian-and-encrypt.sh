#!/bin/bash
#set -x
# Клонируем запущенный линукс установленный на LVM на лету на другой носитель с шифрованием или без.
# Пригодится при переносе ситемы с одного жесткого диска на другой "на лету" не останавливая систему для загрузки с live-cd и прочей ерунды.
# При клонирование можно зашивровать новый носитель с системой при помощи cryptsetup (конечно-же кроме boot раздела).
# Размер нового носителя не ограничен размером томов клонируемой системы, а зависит от общего размера всех фалов клонируемой системы.

# FSTAB_ADD="/dev/raid-vg/data  /mnt/data ext4  errors=remount-ro,noatime,nodiratime 0    2"
# CRYPTTAB_ADD="raid /dev/md0 /root/keyfile luks"
#
# Если в группе (vg_name) нет места под снапшот рута можно указать другой диск для временного расширения группы томов --extend-dev /dev/..., 
# можно указать например --extend-dev /dev/ram0, но стоит учитывать, что по умолчанию это 16MB и может не хватить
# Если указан --extend-dev то размер снапшота (--snapshot-size) будет равен размеру диска для временного расширения

# TODO скрипт нуждается в проверках выполения действий!

function usage {
	echo "usage </dev/disk> <vg_name> <lv_name> [--encrypt-passphrase passphrase] [--encrypt] \
		[--snapshot-size size] [--boot-size size_in_MiB] [--no-rsync] [--extend-dev /dev/...] [--force] \
		[--root-size size] [--swap-size size] [--new-hostname hostname] \
		[--add-crypttab str] [--add-fstab str] [--exclude-dirs '/dir1 /dir2']"
	echo "/dev/disk - диск на который будет клонироваться система, на нем будет создано 2 раздела: boot и остальное место под LVM"
	echo "vg_name - имя группы томов клонируемой системы"
	echo "lv_name - имя тома с рутом клонируемой системы"
	echo "--boot-size size_in_MiB - размер загрузочного раздела в мегабайтах по умолчанию 400"
	echo "--add-crypttab str - строка добавляемая в /etc/crypttab на склонированной системе"
	echo "--add-fstab str - строка добавляемая в /etc/fstab на склонированной системе"
	echo "--exclude-dirs - пропустить каталоги"
	echo "Внимание! Клонируется только root и boot, скрипт не подойдет если var usr home и т.д. на отдельных разделах"
	exit 1
}

DISK=$1
OLD_ROOT_LV=$3
OLD_ROOT_VG=$2

SNAPSHOT_SIZE="200"
RSYNC_OPTIONS=" --one-file-system  -a " # -v --progress 
ROOTMNTTMP="rootmnttmp"

BOOT_SIZE=400


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
--force)
FORCE_RUN="TRUE"
echo "FORCE_RUN"
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
--encrypt-passphrase)
if [  $# == 1 ]; then
        echo "MISSING PASSPHRASE"
        usage
fi
ENCRYPT="TRUE"
PASSPHRASE="$2"
echo "PASSPHRASE $PASSPHRASE"
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
;;
--root-size)
if [  $# == 1 ]; then
	echo "MISSING ROOT_SIZE"
	usage
fi
ROOT_SIZE="$2"
echo "ROOT_SIZE $ROOT_SIZE"
shift
;;
--boot-size)
if [  $# == 1 ]; then
	echo "MISSING BOOT SIZE"
	usage
fi
BOOT_SIZE="$2"
echo "BOOT_SIZE $BOOT_SIZE"
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
--add-crypttab)
if [  $# == 1 ]; then
	echo "MISSING CRYPTTAB_ADD"
	usage
fi
CRYPTTAB_ADD="$2"
echo "CRYPTTAB_ADD $CRYPTTAB_ADD"
shift
;;
--add-fstab)
if [  $# == 1 ]; then
	echo "MISSING FSTAB_ADD"
	usage
fi
FSTAB_ADD="$2"
echo "FSTAB_ADD $FSTAB_ADD"
shift
;;
--exclude-dirs)
if [  $# == 1 ]; then
        echo "MISSING EXCLUDE_DIRS"
        usage
fi
EXCLUDE_DIRS=""
IFS=' ' read -ra DIR <<< "$2"
for i in "${DIR[@]}"; do
    EXCLUDE_DIRS="$EXCLUDE_DIRS --exclude=$i"
done
RSYNC_OPTIONS="$RSYNC_OPTIONS $EXCLUDE_DIRS"
echo "EXCLUDE_DIRS rsync format $EXCLUDE_DIRS"
echo "RSYNC_OPTIONS $RSYNC_OPTIONS"
shift
;;
*)
usage
;;
esac
shift
done

function safe_exit {
	umount $ROOTMNTTMP/dev
	umount $ROOTMNTTMP/proc
	umount $ROOTMNTTMP/sys
	umount $ROOTMNTTMP/boot
	umount $ROOTMNTTMP
	umount $OLD_ROOT_MNT_TMP
        umount $BOOT
	vgreduce --force --removemissing $OLD_ROOT_VG
        vgremove --force $NEW_VG_NAME
	/sbin/lvremove --force /dev/$OLD_ROOT_VG/root-snapshot	
	if [ -n "$EXTEND_DEVICE" ]; then
        	/sbin/vgreduce --force  $OLD_ROOT_VG $EXTEND_DEVICE
	fi
        if [ -n "$ENCRYPT" ]; then
                /sbin/cryptsetup luksClose $CRYPTNAME
        fi
        exit 1
}

NEW_VG_NAME="root`date +%s`"

if [ ! -n "$FORCE_RUN" ]; then
	echo -e "========Warning!\nPlease disable automount (System-Settings - Details - Removable Media)"
	read -p "Press any key to start"
fi

echo "========create disk part table"
parted --script $DISK mktable gpt
if [ $? != 0 ];then
   safe_exit
fi

parted --script $DISK mkpart primary 34sec 2047sec
if [ $? != 0 ];then
   safe_exit
fi

parted --script $DISK set 1 bios_grub
if [ $? != 0 ];then
   safe_exit
fi

parted --script -a optimal $DISK mkpart primary 2048sec $BOOT_SIZE"MiB"
if [ $? != 0 ];then
   safe_exit
fi

START_SIZE=$(expr $BOOT_SIZE + 261)
parted --script -a optimal $DISK mkpart primary $BOOT_SIZE"MiB" $START_SIZE"MiB" 
if [ $? != 0 ];then
   safe_exit
fi

parted --script -a optimal $DISK mkpart primary $START_SIZE"MiB" 100%
if [ $? != 0 ];then
   safe_exit
fi

sleep 1
if [ -e ${DISK}-part1 ]; then
	BOOT=${DISK}-part2
	EFI=${DISK}-part3
	NEW_LVM_PARTIRION=${DISK}-part4
fi

if [ -e ${DISK}1 ]; then
	BOOT=${DISK}2
	EFI=${DISK}3
	NEW_LVM_PARTIRION=${DISK}4
fi

if [ -e ${DISK}p1 ]; then
	BOOT=${DISK}p2
	EFI=${DISK}p3
	NEW_LVM_PARTIRION=${DISK}p4
fi

if [ ! -n "$BOOT" ]; then
	echo "ERROR: PART 1 OF DISK NOT FOUND!"
	exit 1
fi
if [ ! -n "$EFI" ]; then
	echo "ERROR: PART 2 OF DISK NOT FOUND!"
	exit 1
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
	CRYPTNAME="crypt${NEW_VG_NAME}"
	if [  -n "$PASSPHRASE" ];then
		echo -n $PASSPHRASE | /sbin/cryptsetup luksFormat $NEW_LVM_PARTIRION
		if [ $? != 0 ];then
		   safe_exit
		fi
                sleep 2
                echo -n $PASSPHRASE | /sbin/cryptsetup luksOpen $NEW_LVM_PARTIRION $CRYPTNAME
		if [ $? != 0 ];then
		   safe_exit
		fi
	else
		/sbin/cryptsetup luksFormat $NEW_LVM_PARTIRION
		if [ $? != 0 ];then
		   safe_exit
		fi
		sleep 2
		/sbin/cryptsetup luksOpen $NEW_LVM_PARTIRION $CRYPTNAME
		if [ $? != 0 ];then
		   safe_exit
		fi
	fi
	REAL_NEW_LVM_PARTIRION=$NEW_LVM_PARTIRION
	NEW_LVM_PARTIRION=/dev/mapper/$CRYPTNAME

fi

echo "========create lvm"
sleep 2
pvcreate $NEW_LVM_PARTIRION
if [ $? != 0 ];then
	safe_exit
fi

vgcreate $NEW_VG_NAME $NEW_LVM_PARTIRION
if [ $? != 0 ];then
        safe_exit
fi

if [ -n "$SWAP_SIZE" ]; then
	lvcreate $NEW_VG_NAME -n swap -L $SWAP_SIZE
	if [ $? != 0 ];then
	        safe_exit
	fi
	mkswap /dev/mapper/${NEW_VG_NAME}-swap
	if [ $? != 0 ];then
	        safe_exit
	fi
fi

if [ -n "$ROOT_SIZE" ]; then
	lvcreate $NEW_VG_NAME -n root -L $ROOT_SIZE
	if [ $? != 0 ];then
	        safe_exit
	fi
else
	lvcreate $NEW_VG_NAME -n root -l 100%FREE
	if [ $? != 0 ];then
	        safe_exit
	fi
fi
ROOTLVNAME="/dev/${NEW_VG_NAME}/root"
mkfs.ext4 -F -m 0 $ROOTLVNAME
if [ $? != 0 ];then
        safe_exit
fi

#-----------------------------------
ROOTMNTTMP="/mnt/rootmnttmp"
OLD_ROOT_MNT_TMP="/mnt/old-root-mnt-tmp"

echo "========create old root lvm snapshot"
if [ -n "$EXTEND_DEVICE" ]; then
	/sbin/vgextend $OLD_ROOT_VG $EXTEND_DEVICE
	if [ $? != 0 ];then
	        safe_exit
	fi
	vgreduce --removemissing $OLD_ROOT_VG
	SNAPSHOT_SIZE=$(( (`/sbin/blockdev --getsize64 $EXTEND_DEVICE`/1024)/1024 - 4 ))
	SNAPSHOT_SIZE="${SNAPSHOT_SIZE}M"
fi

/sbin/lvcreate --snapshot -n root-snapshot -L ${SNAPSHOT_SIZE} /dev/${OLD_ROOT_VG}/${OLD_ROOT_LV}
if [ $? != 0 ];then
	safe_exit
fi

echo "========mount old root snapshot"
mkdir $OLD_ROOT_MNT_TMP
mount -o ro /dev/$OLD_ROOT_VG/root-snapshot $OLD_ROOT_MNT_TMP
if [ $? != 0 ];then
	safe_exit
fi

sleep 1


mkdir $ROOTMNTTMP
echo "========mount new root"
mount $ROOTLVNAME $ROOTMNTTMP
if [ $? != 0 ];then
	safe_exit
fi

if [ ! -n "$FORCE_RUN" ]; then
	read -p "Press any key to rsync root"
fi
echo "========rsync root"
if [ ! -n "$NORSYNC" ]; then
	rsync $RSYNC_OPTIONS $OLD_ROOT_MNT_TMP/* $ROOTMNTTMP/
	if [ $? != 0 ];then
		if [ -n "$FORCE_RUN" ]; then
			safe_exit
		fi

		echo "RSYNC ERROR! press s to skip";
	        read -s -n 1 KEY
	        if [[ $KEY = "s" ]]; then
			echo "SKIP RSYNC ERROR"
	        else
       			safe_exit
	        fi
	fi
fi

echo "========umount old root snapshot"
umount $OLD_ROOT_MNT_TMP
if [ $? != 0 ];then
        safe_exit
fi

echo "========remove old root lvm snapshot"
/sbin/lvremove --force /dev/$OLD_ROOT_VG/root-snapshot
if [ $? != 0 ];then
        safe_exit
fi

if [ -n "$EXTEND_DEVICE" ]; then
	/sbin/vgreduce $OLD_ROOT_VG $EXTEND_DEVICE
	if [ $? != 0 ];then
        	safe_exit
	fi
fi

echo "========mkfs new boot"
mkfs.ext2 -F -m 5 $BOOT
if [ $? != 0 ];then
	safe_exit
fi

echo "========mkfs efi"
mkfs.vfat $EFI
if [ $? != 0 ];then
        safe_exit
fi

echo "========mount new boot"
mount $BOOT $ROOTMNTTMP/boot
if [ $? != 0 ];then
	safe_exit
fi

echo "========mount new efi"
mkdir -p $ROOTMNTTMP/boot/efi
mount -t vfat $EFI $ROOTMNTTMP/boot/efi
if [ $? != 0 ];then
        safe_exit
fi

if [ ! -n "$FORCE_RUN" ]; then
	read -p "Press any key to rsync boot" 
fi
echo "========rsync boot"
if [ ! -n "$NORSYNC" ]; then
	rsync $RSYNC_OPTIONS  /boot/* $ROOTMNTTMP/boot
	if [ $? != 0 ];then
                if [ -n "$FORCE_RUN" ]; then
                        safe_exit
                fi

                echo "RSYNC ERROR! press s to skip"
		read -s -n 1 KEY
		if [[ $KEY = "s" ]]; then
                       	echo "SKIP RSYNC ERROR"
       	        else
               	        safe_exit
                fi
	fi
fi

echo "========update crypttab and fstab"
BOOT_UUID=`blkid $BOOT | awk '{split($2, a, "\"");  print a[2];}'`
EFI_UUID=`blkid $EFI | awk '{split($3, a, "\"");  print a[2];}'`
rm $ROOTMNTTMP/etc/crypttab
if [ -n "$ENCRYPT" ]; then
	CRYPTDEVUUID=`blkid $REAL_NEW_LVM_PARTIRION | awk '{split($2, a, "\"");  print a[2];}'`
	echo $CRYPTNAME" UUID="$CRYPTDEVUUID" none luks,discard" > $ROOTMNTTMP/etc/crypttab
	if [ -n "$CRYPTTAB_ADD" ]; then
		echo -e $CRYPTTAB_ADD >> $ROOTMNTTMP/etc/crypttab
	fi
fi

echo "/dev/mapper/"$NEW_VG_NAME"-root   /               ext4    errors=remount-ro 0       1" > $ROOTMNTTMP/etc/fstab
echo "UUID="$BOOT_UUID"   /boot               ext2    defaults        0       2" >> $ROOTMNTTMP/etc/fstab
echo "UUID="$EFI_UUID"   /boot/efi           vfat    defaults        0       2" >> $ROOTMNTTMP/etc/fstab
if [ -n "$SWAP_SIZE" ]; then
	echo "/dev/mapper/"$NEW_VG_NAME"-swap   none            swap    sw              0       0" >> $ROOTMNTTMP/etc/fstab
fi
if [ -n "$FSTAB_ADD" ]; then
	echo -e $FSTAB_ADD >> $ROOTMNTTMP/etc/fstab
fi

echo "========mount dev proc sys"
mount -o bind /dev $ROOTMNTTMP/dev
if [ $? != 0 ];then
	safe_exit
fi

mount -t proc none $ROOTMNTTMP/proc
if [ $? != 0 ];then
        safe_exit
fi

mount -t sysfs none $ROOTMNTTMP/sys
if [ $? != 0 ];then
        safe_exit
fi

#echo "========install grub"
#chroot $ROOTMNTTMP grub-install ${DISK}
#if [ $? != 0 ];then
#        safe_exit
#fi

chroot $ROOTMNTTMP grub-install --target=x86_64-efi ${DISK}
if [ $? != 0 ];then
        safe_exit
fi

echo "========update-initramfs"
chroot $ROOTMNTTMP update-initramfs -k all -c
if [ $? != 0 ];then
        safe_exit
fi

echo "========udate grub"
chroot $ROOTMNTTMP update-grub ${DISK}
if [ $? != 0 ];then
        safe_exit
fi

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
lvchange -a n /dev/$NEW_VG_NAME/root
lvchange -a n /dev/$NEW_VG_NAME/swap
vgchange -a n $NEW_VG_NAME

sleep 5
if [ -n "$ENCRYPT" ]; then
	/sbin/cryptsetup luksClose $CRYPTNAME
fi
