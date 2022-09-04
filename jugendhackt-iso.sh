#!/usr/bin/env bash

set -e

UEFI_NTFS_URL="https://github.com/pbatard/rufus/blob/master/res/uefi/uefi-ntfs.img?raw=true"

USB=$1
ISO=$2

if [[ "--help" == "$USB" || "-h" == "$USB" || -z "$USB" || -z "$ISO" ]]; then
	echo "Bootstraps a persistent Ubuntu-based live system on a USB stick"
	echo ""
	echo "jugendhackt-iso.sh <usb-device> <iso-file>"
	echo ""
	echo "Author: The one with the braid <the-one@with-the-braid.cf>"
	exit 0
fi

REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following p
ackages are installed:\n\n- mkfs.ntfs (ntfs-3g)\n- rsync (rsync)\n- wget (wget)\n- gdisk (gdisk)"

for COMMAND in "mkfs.ntfs rsync wget gdisk"
do
	if [[ -x "$(command -v $COMMAND)" ]]; then
		echo -e "${COMMAND}${REQUIRED_LIBRARIES}"
		exit 1
	fi
done

if [[ $EUID != 0 ]]; then
	echo "Please do not run as root"
	exit 1
fi

echo "Preparing temporary files..."

ISO_MOUNT="$(mktemp -d)"
USB_MOUNT="$(mktemp -d)"

mount -t iso9660 -o ro "$ISO" "$ISO_MOUNT"

UEFI_NTFS_FILE="$(mktemp)"

echo "Downloading UEFI_NTFS driver..."

wget --output-document="$UEFI_NTFS_FILE" "$UEFI_NTFS_URL"

echo "Partitioning disk..."

PART_1_SIZE="$(stat -c '%s' $UEFI_NTFS_FILE)"
PART_2_SIZE="$(du -s $ISO_MOUNT | cut -f1)"

(
echo o
echo y

echo n
echo 1
echo ""
echo "+${PART_1_SIZE}B"
echo "ef00"

echo n
echo 2
echo ""
echo "+$(( $PART_2_SIZE + 1024 ))K"
echo "0700"

echo n
echo 3
echo ""
echo ""
echo ""

echo w
echo Y
) | sudo gdisk "$USB"

echo "Bootstrapping filesystems..."

dd if="$UEFI_NTFS_FILE" bs="$(stat -c '%b' $UEFI_NTFS_FILE)" of="${USB}1"

mkfs.ntfs -f -L "Jugend hackt Live" "${USB}2"
mkfs.ext4 -F -L "casper-rw" "${USB}3"

mount "${USB}3" "$USB_MOUNT"

rsync -lr "$ISO_MOUNT"/* "$USB_MOUNT"

echo "Patching bootloader config..."

CMDLINE_FILES="/boot/grub/loopback.cfg /boot/grub/grub.cfg /isolinux/menuentries.cfg"

for FILE in $CMDLINE_FILES
do
	sed -i 's/---/persistent fsck.mode=skip ---/g' "${USB_MOUNT}${FILE}"
	sed -i 's/(maybe|only)-ubiquity//g' "${USB_MOUNT}${FILE}"
done

echo "Syncing drive..."

sync "$USB"

echo "Removing temporary files..."

umount "$ISO_MOUNT"
umount "$USB_MOUNT"

rmdir "$ISO_MOUNT"
rmdir "$USB_MOUNT" 

rm "$UEFI_NTFS_FILE"

echo "Done."

exit
