#!/usr/bin/env bash

set -e

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

REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following packages are installed:\n\n- gdisk (gdisk)\n- rsync (rsync)\n- wget (wget)\n- parted (parted)\n- mkfs.msdos (dosfstools)\n- unsquashfs, mksquashfs (squashfs-tools)"

for COMMAND in rsync wget parted gdisk unsquashfs mksquashfs; do
	if [[ ! -x "$(command -v $COMMAND)" ]]; then
		echo -e "${COMMAND}${REQUIRED_LIBRARIES}"
		exit 1
	fi
done

if [[ ! -f config ]]; then
	echo "Please copy ./config.sample to ./config and adjust it to your needs"
	exit 1
fi

source "./config"

if [[ $EUID != 0 ]]; then
	echo "Please run this script as root in order to access block devices."
	exit 1
fi

echo "Analyzing source iso..."

SOURCE_ISO_CHECKSUM="$(sha256sum "${ISO}" | awk '{ print $1 }')"
CONFIG_CHECKSUM="$(sha256sum config | awk '{ print $1 }')"

IDENTIFIER="${SOURCE_ISO_CHECKSUM}-${CONFIG_CHECKSUM}"

echo "Creating mount points..."

ISO_MOUNT="$(mktemp -d)"
USB_MOUNT="$(mktemp -d)"
SQUASHFS_ROOT="$(mktemp -u)"

mount -t iso9660 -o ro "${ISO}" "${ISO_MOUNT}"

ISO_SIZE="$(du -s "${ISO_MOUNT}" | cut -f1)"

umount -f "$USB"* || true

if [[ -f "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" ]]; then

	echo "Using existing squashfs..."

else

	echo "Patching live environment..."

	TMP_FREE="$(df --output=iavail /tmp | tail -n1)"
	TMP_SIZE="$(df --output=itotal /tmp | tail -n1)"

	if (($TMP_FREE < $ISO_SIZE * 8 * 1024)); then
		if [[ -n "$(mount | grep "/tmp ")" ]]; then
			mount -o remount,size="$(($TMP_SIZE + $ISO_SIZE * 8 * 1024))" "/tmp" || true
		fi
	fi

	unsquashfs -d "${SQUASHFS_ROOT}" "${ISO_MOUNT}/casper/minimal.squashfs"

	for MOUNTPOINT in dev dev/pts sys proc; do
		mount -B "/$MOUNTPOINT" "${SQUASHFS_ROOT}/${MOUNTPOINT}"
	done

	mkdir "${SQUASHFS_ROOT}/cdrom"
	mkdir "${SQUASHFS_ROOT}/boot/efi"

	mv "$SQUASHFS_ROOT/etc/resolv.conf" "$SQUASHFS_ROOT/etc/resolv.conf.backup"
	echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" >"${SQUASHFS_ROOT}/etc/resolv.conf"

	chroot "$SQUASHFS_ROOT" apt update -qq
	chroot "$SQUASHFS_ROOT" apt purge -qq -y "$PACKAGE_REMOVAL"

	if [[ "${PERFORM_SYSTEM_UPGRADE}" == "true" ]]; then
		chroot "$SQUASHFS_ROOT" apt dist-upgrade -qq -y
	fi

	chroot "$SQUASHFS_ROOT" apt autoremove -qq -y
	chroot "$SQUASHFS_ROOT" apt install -qq -y software-properties-common
	chroot "$SQUASHFS_ROOT" add-apt-repository -y main
	chroot "$SQUASHFS_ROOT" add-apt-repository -y universe
	chroot "$SQUASHFS_ROOT" add-apt-repository -y multiverse
	chroot "$SQUASHFS_ROOT" apt update -qq
	chroot "$SQUASHFS_ROOT" apt install -qq -y --no-install-recommends flatpak gnome-software-plugin-flatpak fwupd ntfs-3g casper ubiquity-casper initramfs-tools live-boot-initramfs-tools live-boot live-tools linux-generic packagekit locales grub2 grub-pc grub-efi-amd64-signed

	if [[ -z "$ADDITIONAL_REPOSITORIES" ]]; then
		for PPA in $ADDITIONAL_REPOSITORIES; do
			echo "Adding apt repository ${PPA}"
			chroot "$SQUASHFS_ROOT" add-apt-repository -y "$PPA"
		done
	else
		echo "No additional apt repositories to add."
	fi

	if [[ -z "$KEYBOARD_LAYOUT" ]]; then
		KEYBOARD_LAYOUT="us"
	fi

	if [[ -z "$LANGUAGE" ]]; then
		LANGUAGE="en_US"
	fi

	sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$KEYBOARD_LAYOUT'\"/g' "${SQUASHFS_ROOT}/etc/default/keyboard"
	chroot "$SQUASHFS_ROOT" /usr/sbin/update-locale LANG="${LANGUAGE}.UTF-8"

	echo "Installing additional packages"
	chroot "$SQUASHFS_ROOT" apt install -qq -y $ADDITIONAL_PACKAGES
	chroot "$SQUASHFS_ROOT" apt clean
	chroot "$SQUASHFS_ROOT" rm -rf /var/cache/apt/* || true

	echo "Installing additional flatpaks..."
	yes | chroot "$SQUASHFS_ROOT" flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
	for FLATPAK in $ADDITIONAL_FLATPAKS; do
		chroot "$SQUASHFS_ROOT" flatpak install --noninteractive --system --or-update -y flathub "$FLATPAK"
	done

	mv "$SQUASHFS_ROOT/etc/resolv.conf.backup" "$SQUASHFS_ROOT/etc/resolv.conf"

	for MOUNTPOINT in dev/pts dev sys proc; do
		umount "${SQUASHFS_ROOT}/${MOUNTPOINT}"
	done

	if [[ ! -d /var/cache/jugendhackt-iso ]]; then
		mkdir "/var/cache/jugendhackt-iso"
	fi

	mksquashfs "$SQUASHFS_ROOT" "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs"
	echo "Keeping squashfs cached at /var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs for later use. Remove in order to clean up space."

fi

SQUASHFS_SIZE="$(du -s "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" | cut -f1)"

PART_2_SIZE="$(($ISO_SIZE + SQUASHFS_SIZE))"

echo "Preparing temporary files..."

parted --script "$USB" mklabel gpt
sync

(
	echo o
	echo y

	echo n
	echo 4
	echo ""
	echo "+1M"
	echo "ef02"

	echo n
	echo 1
	echo ""
	echo "+512M"
	echo "ef00"

	echo n
	echo 2
	echo ""
	echo "+$(($PART_2_SIZE + 1024))"K
	echo ""

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

yes | mkfs.msdos -n "ESP" "${USB}1"
yes | mkfs.msdos -n "BIOS" "${USB}4"
mkfs.ext4 -F -L "Jugend hackt Live" "${USB}2"
mkfs.ext4 -F -L "casper-rw" "${USB}3"

tune2fs -O ^metadata_csum_seed "${USB}2"
tune2fs -O ^metadata_csum_seed "${USB}3"

mount "${USB}2" "${USB_MOUNT}"

echo "Copying installation media"

rsync -lr --exclude "casper/minimal.squashfs" "$ISO_MOUNT"/* "$USB_MOUNT"

cp "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" "${USB_MOUNT}/casper/minimal.squashfs"

echo "Patching bootloader config..."

LINUX_TMP="$(mktemp -u)"

unsquashfs -d "${LINUX_TMP}" "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" /boot -/boot/grub

rm "${USB_MOUNT}"/casper/vmlinu* "${USB_MOUNT}"/casper/initrd*
cp "${LINUX_TMP}/boot/vmlinuz" "${LINUX_TMP}/boot/initrd.img" "${USB_MOUNT}/casper/"

rm -rf "${LINUX_TMP}"

if [[ -d "${USB_MOUNT}/isolinux" ]]; then
	rm -rf "${USB_MOUNT}/isolinux"
fi

CMDLINE_FILES="/boot/grub/loopback.cfg /boot/grub/grub.cfg"

for FILE in $CMDLINE_FILES; do
	if [[ -f "${USB_MOUNT}${FILE}" ]]; then
		sed -i 's/---/boot=casper persistent fsck.mode=skip noprompt locale='"${LANGUAGE}.UTF-8"' keyb='"${KEYBOARD_LAYOUT}"'---/g' "${USB_MOUNT}${FILE}"
		sed -i 's/\(maybe\|only\)-ubiquity//g' "${USB_MOUNT}${FILE}"
		sed -i 's/initrd\(=\|\s*\)[[:graph:]]*/initrd\1\/casper\/initrd.img/g' "${USB_MOUNT}${FILE}"
		sed -i 's/\(linux\|KERNEL\)\(\s*\)[[:graph:]]*/\1\2\/casper\/vmlinuz/g' "${USB_MOUNT}${FILE}"
	fi
done

echo "Installing grub"

SQUASHFS_TMP="$(mktemp -d)"
CDROM_TMP="${SQUASHFS_TMP}/cdrom"
ESP_TMP="${SQUASHFS_TMP}/boot/efi"

mkdir -p "${ESP_TMP}" || true
mkdir -p "${CDROM_TMP}" || true

mount -o ro "${USB_MOUNT}/casper/minimal.squashfs" "${SQUASHFS_TMP}"
mount "${USB}1" "${ESP_TMP}"
mount "${USB}2" "${CDROM_TMP}"

for MOUNTPOINT in dev dev/pts sys proc; do
	mount -B "/$MOUNTPOINT" "${SQUASHFS_TMP}/${MOUNTPOINT}"
done

chroot "${SQUASHFS_TMP}" /usr/sbin/grub-install --target=i386-pc --boot-directory="/cdrom/boot" "${USB}" || true
chroot "${SQUASHFS_TMP}" /usr/sbin/grub-install --removable --target=x86_64-efi --no-nvram --uefi-secure-boot --boot-directory="/cdrom/boot" --efi-directory="/boot/efi"

for MOUNTPOINT in dev/pts dev sys proc; do
	umount "${SQUASHFS_TMP}/${MOUNTPOINT}"
done

umount "${ESP_TMP}"
umount "${CDROM_TMP}"
umount "${SQUASHFS_TMP}"

rmdir "${SQUASHFS_TMP}"

echo "Syncing drive..."

sync "$USB"

echo "Removing temporary files..."

umount "$ISO_MOUNT"
umount "$USB_MOUNT"

rmdir "$ISO_MOUNT"
rmdir "$USB_MOUNT"

rm -rf "$SQUASHFS_ROOT"

echo "Done."

exit
