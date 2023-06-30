#!/usr/bin/env bash

set -e

USB=$1

if [[ "--help" == "$USB" || "-h" == "$USB" || -z "$USB" ]]; then
	echo "Bootstraps a persistent Ubuntu-based live system on a USB stick"
	echo ""
	echo "jugendhackt-iso.sh <usb-device>"
	echo ""
	echo "Author: The one with the braid <the-one@with-the-braid.cf>"
	exit 0
fi

REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following packages are installed:\n\n- debootstrap (debootstrap)\n-rsync (rsync)\n- gdisk (gdisk)\n- parted (parted)\n- mkfs.msdos (dosfstools)\n- unsquashfs, mksquashfs (squashfs-tools)"

for COMMAND in debootstrap rsync gdisk parted mkfs.msdos unsquashfs mksquashfs; do
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

CONFIG_CHECKSUM="$(sha256sum config | awk '{ print $1 }')"

IDENTIFIER="${CONFIG_CHECKSUM}"

echo "Creating mount points..."

USB_MOUNT="$(mktemp -d)"
DEBOOTSTRAP_ROOT="/var/cache/jugendhackt-iso/build/${IDENTIFIER}"

umount -f "$USB"* || true

if [[ -f "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" ]]; then

	echo "Using existing squashfs..."

else

	echo "Bootstrapping live environment..."

	debootstrap "$RELEASE_BASE" "${DEBOOTSTRAP_ROOT}" "$RELEASE_MIRROR"

	for MOUNTPOINT in dev dev/pts sys proc; do
		mount -B "/$MOUNTPOINT" "${DEBOOTSTRAP_ROOT}/${MOUNTPOINT}"
	done

	mkdir "${DEBOOTSTRAP_ROOT}/cdrom"
	mkdir "${DEBOOTSTRAP_ROOT}/boot/efi"

	mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf" "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup"
	echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" >"${DEBOOTSTRAP_ROOT}/etc/resolv.conf"

	chroot "$DEBOOTSTRAP_ROOT" apt update -qq
	chroot "$DEBOOTSTRAP_ROOT" apt purge -qq -y "$PACKAGE_REMOVAL"

	chroot "$DEBOOTSTRAP_ROOT" apt autoremove -qq -y
	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y software-properties-common
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y main
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y universe
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y multiverse
	chroot "$DEBOOTSTRAP_ROOT" apt update -qq

	if [[ -z "$ADDITIONAL_REPOSITORIES" ]]; then
		for PPA in $ADDITIONAL_REPOSITORIES; do
			echo "Adding apt repository ${PPA}"
			chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y "$PPA"
		done
	else
		echo "No additional apt repositories to add."
	fi

	echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | chroot "$DEBOOTSTRAP_ROOT" debconf-set-selections

	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y ubuntu-desktop-minimal ubuntu-restricted-extras language-pack-${KEYBOARD_LAYOUT} language-pack-gnome-${KEYBOARD_LAYOUT} language-pack-${KEYBOARD_LAYOUT}-base language-pack-gnome-${KEYBOARD_LAYOUT}-base flatpak gnome-software-plugin-flatpak fwupd ntfs-3g casper ubiquity-casper initramfs-tools live-boot-initramfs-tools live-boot live-tools linux-generic packagekit locales grub2 grub-pc grub-efi-amd64-signed
	
	if [[ -z "$KEYBOARD_LAYOUT" ]]; then
		KEYBOARD_LAYOUT="us"
	fi

	if [[ -z "$LANGUAGE" ]]; then
		LANGUAGE="en_US"
	fi

	sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$KEYBOARD_LAYOUT'\"/g' "${DEBOOTSTRAP_ROOT}/etc/default/keyboard"
	chroot "$DEBOOTSTRAP_ROOT" /usr/sbin/update-locale LANG="${LANGUAGE}.UTF-8"

	echo "Installing additional packages"
	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y $ADDITIONAL_PACKAGES
	chroot "$DEBOOTSTRAP_ROOT" apt clean
	chroot "$DEBOOTSTRAP_ROOT" rm -rf /var/cache/apt/* || true

	echo "Installing additional flatpaks..."
	yes | chroot "$DEBOOTSTRAP_ROOT" flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
	for FLATPAK in $ADDITIONAL_FLATPAKS; do
		chroot "$DEBOOTSTRAP_ROOT" flatpak install --noninteractive --system --or-update -y flathub "$FLATPAK"
	done

	mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup" "$DEBOOTSTRAP_ROOT/etc/resolv.conf"

	for MOUNTPOINT in dev/pts dev sys proc; do
		umount "${DEBOOTSTRAP_ROOT}/${MOUNTPOINT}"
	done

	if [[ ! -d /var/cache/jugendhackt-iso ]]; then
		mkdir "/var/cache/jugendhackt-iso"
	fi

	mksquashfs "$DEBOOTSTRAP_ROOT" "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs"
	echo "Keeping squashfs cached at /var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs for later use. Remove in order to clean up space."

fi

SQUASHFS_SIZE="$(du -s "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" | cut -f1)"

PART_2_SIZE="$((500000 + SQUASHFS_SIZE))"

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

echo "Copying live media"

mkdir "${USB_MOUNT}/casper"
cp "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" "${USB_MOUNT}/casper/filesystem.squashfs"

echo "Patching bootloader config..."

LINUX_TMP="$(mktemp -u)"

unsquashfs -d "${LINUX_TMP}" "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" /boot

cp "${LINUX_TMP}/boot/vmlinuz" "${LINUX_TMP}/boot/initrd.img" "${USB_MOUNT}/casper/"

rm -rf "${LINUX_TMP}"

echo "Installing grub"

mkdir -p "${USB_MOUNT}/boot/grub" 
cat <<EOF > "${USB_MOUNT}/boot/grub/grub.cfg"
set timeout=30

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Try Ubuntu (persistent)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz boot=casper persistent fsck.mode=skip noprompt locale="${LANGUAGE}.UTF-8" keyb="${KEYBOARD_LAYOUT}" quiet splash
	initrd	/casper/initrd.img
}
grub_platform
if [ "\$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
	exit 1
}
menuentry 'UEFI Firmware Settings' {
	fwsetup
}
else
menuentry 'Test memory' {
	linux16 /boot/memtest86+x64.bin
}
fi

EOF

SQUASHFS_TMP="$(mktemp -d)"
CDROM_TMP="${SQUASHFS_TMP}/cdrom"
ESP_TMP="${SQUASHFS_TMP}/boot/efi"

mkdir -p "${ESP_TMP}" || true
mkdir -p "${CDROM_TMP}" || true

mount -o ro "${USB_MOUNT}/casper/filesystem.squashfs" "${SQUASHFS_TMP}"
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

rm -rf "${SQUASHFS_TMP}"

echo "Syncing drive..."

sync "$USB"

echo "Removing temporary files..."

umount "$USB_MOUNT"

rmdir "$USB_MOUNT"

rm -rf "$DEBOOTSTRAP_ROOT"

echo "Done."

exit
