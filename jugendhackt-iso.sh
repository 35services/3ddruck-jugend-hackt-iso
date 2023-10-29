#!/usr/bin/env bash

set -e

STAGE=$1
USB=$2
PART_BASE="${USB}"

if [[ $USB = /dev/nvme* ]]; then
  PART_BASE="${USB}p"
fi

if [[ "--help" == "$STAGE" || "-h" == "$STAGE" || -z "$STAGE" || "flash" == "$STAGE" && -z "$USB" ]]; then
	echo "Bootstraps a persistent Ubuntu-based live system on a USB stick"
	echo ""
	echo "1. Build a the cache for later bulk flash"
	echo "> jugendhackt-iso.sh build"
	echo ""
	echo "2. Flash the cached build onto a given USB drive"
	echo "> jugendhackt-iso.sh flash <usb-device>"
	echo ""
	echo "Author: The one with the braid <info@braid.business>"
	exit 0
fi

REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following packages are installed:\n\n- debootstrap (debootstrap)\n- gdisk (gdisk)\n- parted (parted)\n- mkfs.msdos (dosfstools)\n- unsquashfs, mksquashfs (squashfs-tools)\n - udevadm (udev)"

for COMMAND in debootstrap gdisk parted mkfs.msdos unsquashfs mksquashfs udevadm; do
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
SQUASHFS_FILE="/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs"

if [[ ! -f "${SQUASHFS_FILE}" ]]; then
	if [[ "build" != "$STAGE" ]]; then
		echo "${SQUASHFS_FILE} not found. Please run first : $0 build"
		exit 1
	fi

	echo "Bootstrapping live environment..."
	
	DEBOOTSTRAP_ROOT="$(mktemp -d)"

	debootstrap "$RELEASE_BASE" "${DEBOOTSTRAP_ROOT}" "$RELEASE_MIRROR"

	for MOUNTPOINT in dev dev/pts sys proc; do
		mount -B "/$MOUNTPOINT" "${DEBOOTSTRAP_ROOT}/${MOUNTPOINT}"
	done

	mkdir "${DEBOOTSTRAP_ROOT}/cdrom"
	mkdir "${DEBOOTSTRAP_ROOT}/boot/efi"

	mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf" "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup"
	echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" >"${DEBOOTSTRAP_ROOT}/etc/resolv.conf"
	
	# create APT system user
	chroot "$DEBOOTSTRAP_ROOT" adduser --force-badname --system --home /nonexistent --no-create-home --quiet _apt || true
	chroot "$DEBOOTSTRAP_ROOT" apt update -qq
	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y software-properties-common
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y main
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y universe
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y multiverse
	chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y restricted

	if [[ ! -z "$ADDITIONAL_REPOSITORIES" ]]; then
		for PPA in $ADDITIONAL_REPOSITORIES; do
			echo "Adding apt repository ${PPA}"
			chroot "$DEBOOTSTRAP_ROOT" add-apt-repository -y "$PPA"
		done
	else
		echo "No additional apt repositories to add."
	fi

	# enabling source packages for advanced package search
	for file in "${DEBOOTSTRAP_ROOT}/etc/apt/sources.list" "${DEBOOTSTRAP_ROOT}/etc/apt/sources.list.d/"*; do
		sed -i '/deb-src/s/^# //' $file
	done
	
	chroot "$DEBOOTSTRAP_ROOT" apt update -qq

	echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | chroot "$DEBOOTSTRAP_ROOT" debconf-set-selections
	echo "set passwd/user-default-groups adm cdrom sudo dip plugdev lpadmin sambashare operator dialout audio video debian-tor lxd" | chroot "$DEBOOTSTRAP_ROOT" debconf-set-selections

	# overwriting package source priorities for Firefox
	cat <<EOF > "${DEBOOTSTRAP_ROOT}/etc/apt/preferences.d/mozillateam"
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 100

Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

	if [[ -z "$KEYBOARD_LAYOUT" ]]; then
		KEYBOARD_LAYOUT="us"
	fi

	if [[ -z "$LANGUAGE" ]]; then
		LANGUAGE="en_US"
	fi

	if [[ -z "$LANGUAGE_PACK" ]]; then
		LANGUAGE_PACK="en"
	fi

	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y ubuntu-desktop ubuntu-restricted-extras language-pack-${LANGUAGE_PACK} language-pack-gnome-${LANGUAGE_PACK} language-pack-${LANGUAGE_PACK}-base language-pack-gnome-${LANGUAGE_PACK}-base flatpak gnome-software-plugin-flatpak fwupd ntfs-3g casper ubiquity-casper initramfs-tools live-boot-initramfs-tools live-boot live-tools linux-generic packagekit locales grub2 grub-pc grub-efi-amd64-signed
	
	sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$KEYBOARD_LAYOUT'\"/g' "${DEBOOTSTRAP_ROOT}/etc/default/keyboard"
	chroot "$DEBOOTSTRAP_ROOT" /usr/sbin/update-locale LANG="${LANGUAGE}.UTF-8"

	echo "Installing additional packages"
	chroot "$DEBOOTSTRAP_ROOT" apt install -qq -y $ADDITIONAL_PACKAGES
	chroot "$DEBOOTSTRAP_ROOT" apt purge -qq -y $PACKAGE_REMOVAL

	chroot "$DEBOOTSTRAP_ROOT" apt autoremove -qq -y
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

	rm -rf "$DEBOOTSTRAP_ROOT"

else

	if [[ "flash" != "$STAGE" ]]; then
		echo "${SQUASHFS_FILE} already found. If you want to force a rebuild, manually delete this file."
		exit 1
	fi

	echo "Creating mount points..."

	USB_MOUNT="$(mktemp -d)"

	umount -f "$USB"* || true

	SQUASHFS_SIZE="$(du -s "/var/cache/jugendhackt-iso/${IDENTIFIER}.squashfs" | cut -f1)"

	PART_2_SIZE="$((500000 + SQUASHFS_SIZE))"

	echo "Preparing temporary files..."

	parted --script "$USB" mklabel gpt
	sync "$USB"

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
	) | gdisk "$USB"

	parted --script "$USB" set 4 bios_grub on

	sync "$USB"

	echo "Bootstrapping filesystems..."

	yes | mkfs.msdos -n "ESP" "${PART_BASE}1"
	yes | mkfs.msdos -n "BIOS" "${PART_BASE}4"
	mkfs.ext4 -F -L "Jugend hackt Live" "${PART_BASE}2"
	mkfs.ext4 -F -L "casper-rw" "${PART_BASE}3"

	tune2fs -O ^metadata_csum_seed "${PART_BASE}2"
	tune2fs -O ^metadata_csum_seed "${PART_BASE}3"

	mount "${PART_BASE}2" "${USB_MOUNT}"

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
fi

EOF

	SQUASHFS_TMP="$(mktemp -d)"
	CDROM_TMP="${SQUASHFS_TMP}/cdrom"
	ESP_TMP="${SQUASHFS_TMP}/boot/efi"

	mkdir -p "${ESP_TMP}" || true
	mkdir -p "${CDROM_TMP}" || true

	mount -o ro "${USB_MOUNT}/casper/filesystem.squashfs" "${SQUASHFS_TMP}"
	mount "${PART_BASE}1" "${ESP_TMP}"
	mount "${PART_BASE}2" "${CDROM_TMP}"

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

fi

echo "Done."

exit
