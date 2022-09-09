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
ackages are installed:\n\n- mkfs.ntfs (ntfs-3g)\n- rsync (rsync)\n- wget (wget)\n- parted (parted)\n- unsquashfs, mksquashfs (squashfs-tools)"

for COMMAND in "mkfs.ntfs rsync wget parted unsquashfs mksquashfs"
do
	if [[ -x "$(command -v $COMMAND)" ]]; then
		echo -e "${COMMAND}${REQUIRED_LIBRARIES}"
		exit 1
	fi
done

if [[ ! -f config ]]; then
	echo "Please copy ./config.sample to ./config and adjust it to your needs"
	exit 1
fi

if [[ $EUID != 0 ]]; then
	echo "Please do not run as root"
	exit 1
fi

echo "Preparing temporary files..."

ISO_MOUNT="$(mktemp -d)"
USB_MOUNT="$(mktemp -d)"
SQUASHFS_ROOT="$(mktemp -d)"

mount -t iso9660 -o ro "$ISO" "$ISO_MOUNT"

UEFI_NTFS_FILE="$(mktemp)"

echo "Downloading UEFI_NTFS driver..."

wget --output-document="$UEFI_NTFS_FILE" "$UEFI_NTFS_URL"

echo "Partitioning disk..."

PART_1_SIZE="$(stat -c '%s' $UEFI_NTFS_FILE)"
PART_2_SIZE="$(du -s $ISO_MOUNT | cut -f1)"

umount -f "$USB"* || true

parted --script /dev/sda mklabel gpt; sync

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
echo "+$(( $PART_2_SIZE + 1024 ))"K
echo "0700"

echo n
echo 3
echo ""
echo ""
echo ""

echo w
echo Y
) | sudo gdisk "$USB"

sync

echo "Bootstrapping filesystems..."

dd if="$UEFI_NTFS_FILE" bs="$(stat -c '%b' $UEFI_NTFS_FILE)" of="${USB}1"

mkfs.ntfs -f -L "Jugend hackt Live" "${USB}2"
mkfs.ext4 -F -L "casper-rw" "${USB}3"

mount "${USB}2" "$USB_MOUNT"

rsync -lr --exclude "casper/filesystem.squashfs" "$ISO_MOUNT"/* "$USB_MOUNT"

echo "Patching live environment..."

TMP_FREE="$(df --output=iavail /tmp | tail -n1)"
TMP_SIZE="$(df --output=itotal /tmp | tail -n1)"

if (( $TMP_FREE < $PART_2_SIZE * 4 * 1024 )); then
       if [[ -n "$(mount | grep /tmp)" ]]; then
		mount -o remount,size="$(( $TMP_SIZE + $PART_2_SIZE * 8 * 1024 ))" "/tmp" || true
       fi
fi

unsquashfs -d "$SQUASHFS_ROOT" "${ISO_MOUNT}/casper/filesystem.squashfs"

for MOUNTPOINT in dev dev/pts sys proc
do
	mount -B "/$MOUNTPOINT" "${SQUASHFS_ROOT}/${MOUNTPOINT}"
done

mv "$SQUASHFS_ROOT/etc/resolv.conf" "$SQUASHFS_ROOT/etc/resolv.conf.backup"
echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" > "${SQUASHFS_ROOT}/etc/resolv.conf"

chroot "$SQUASHFS_ROOT" apt update -qq
chroot "$SQUASHFS_ROOT" apt purge -qq -y "$PACKAGE_REMOVAL"
chroot "$SQUASHFS_ROOT" apt dist-upgrade -qq -y
chroot "$SQUASHFS_ROOT" apt autoremove -qq -y
chroot "$SQUASHFS_ROOT" apt install software-properties-common flatpak gnome-software-plugin-flatpak

for PPA in $ADDITIONAL_REPOSITORIES
do
	chroot "$SQUASHFS_ROOT" add-apt-repository -y "$PPA"
done

chroot "$SQUASHFS_ROOT" apt install -qq -y "$ADDITIONAL_PACKAGES"
chroot "$SQUASHFS_ROOT" apt clean
chroot "$SQUASHFS_ROOT" rm -rf /var/cache/apt/*

yes | chroot "$SQUASHFS_ROOT" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
for FLATPAK in $ADDITIONAL_FLATPAKS
do
	yes | chroot "$SQUASHFS_ROOT" flatpak install flathub "$FLATPAK"
done

mv "$SQUASHFS_ROOT/etc/resolv.conf.backup" "$SQUASHFS_ROOT/etc/resolv.conf"

for MOUNTPOINT in dev/pts dev sys proc
do
	umount "${SQUASHFS_ROOT}/${MOUNTPOINT}"
done

mksquashfs "$SQUASHFS_ROOT" "${USB_MOUNT}/casper/filesystem.squashfs"

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

rm -rf "$SQUASHFS_ROOT"
rm "$UEFI_NTFS_FILE"

echo "Done."

exit
