#!/usr/bin/env bash

set -e

STAGE=$1
USB=$2

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

REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following packages are installed:\n\n- debootstrap (debootstrap)\n- gdisk (gdisk)\n- parted (parted)\n- mkfs.msdos (dosfstools)\n- unsquashfs, mksquashfs (squashfs-tools)\n - udevadm (udev)\n - bwrap (bubblewrap)"

for COMMAND in debootstrap gdisk parted mkfs.msdos unsquashfs mksquashfs udevadm bwrap; do
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
CACHE_PATH="${CACHE_PATH-/var/cache/jugendhackt-iso}"
SQUASHFS_FILE="${CACHE_PATH}/${IDENTIFIER}.squashfs"

if [[ -z "$KEYBOARD_LAYOUT" ]]; then
  KEYBOARD_LAYOUT="us"
fi

if [[ -z "$LANGUAGE" ]]; then
  LANGUAGE="en_US"
fi

if [[ -z "$LANGUAGE_PACK" ]]; then
  LANGUAGE_PACK="en"
fi

function mount_chroot() {
  CHROOT="$1"

  # self-bind in order to fix "bwrap: Failed to make master / slave: Invalid argument"
  # see https://github.com/flatpak/flatpak/issues/703#issuecomment-293250243
	mount --bind "${CHROOT}" "${CHROOT}"

  mount proc "$CHROOT/proc" -t proc -o nosuid,noexec,nodev
  mount sys "$CHROOT/sys" -t sysfs -o nosuid,noexec,nodev,ro
  mount udev "$CHROOT/dev" -t devtmpfs -o mode=0755,nosuid
  mount devpts "$CHROOT/dev/pts" -t devpts -o mode=0620,gid=5,nosuid,noexec
  mount shm "$CHROOT/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev
  mount tmp "$CHROOT/tmp" -t tmpfs -o mode=1777,strictatime,nodev,nosuid
}

function umount_chroot() {
  CHROOT="$1"

  umount "$CHROOT/tmp"
  umount "$CHROOT/dev/shm"
  umount "$CHROOT/dev/pts"
  umount "$CHROOT/dev"
  umount "$CHROOT/sys"
  umount "$CHROOT/proc"

  umount "$CHROOT"
}

chroot_env () {
	chroot "$1" \
		/usr/bin/env -i \
		DEBIAN_FRONTEND=noninteractive \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/games:/usr/games \
		XDG_CONFIG_DIRS=/etc/xdg \
		DEFAULT_XDG_CONFIG_DIRS=/etc/xdg \
		XDG_DATA_DIRS=/usr/local/share/:/usr/share/:/var/lib/flatpak/exports/share \
		XDG_DATA_HOME=/usr/local/share/:/usr/share/:/var/lib/flatpak/exports/share \
		DEFAULT_XDG_DATA_DIRS=/usr/local/share/:/usr/share/ \
		"${@:2}"
}

bwrap_env () {
	bwrap \
		--bind "$1" / \
		--dev /dev \
		--proc /proc \
		--bind /sys /sys \
		--bind /run /run \
		--clearenv \
		--setenv DEBIAN_FRONTEND noninteractive \
		--setenv XDG_CURRENT_DESKTOP GNOME \
		--setenv GDMSESSION gnome \
		--setenv DESKTOP_SESSION gnome \
		--setenv PATH /usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/games:/usr/games \
		--setenv XDG_CONFIG_DIRS /etc/xdg \
		--setenv DEFAULT_XDG_CONFIG_DIRS /etc/xdg \
		--setenv XDG_DATA_DIRS /usr/share/gnome:/home/user/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share \
		--setenv XDG_DATA_HOME /usr/local/share/:/usr/share/:/var/lib/flatpak/exports/share \
		--setenv DEFAULT_XDG_DATA_DIRS /usr/local/share/:/usr/share/ \
		"${@:2}"
}


function build_squashfs() {
  DEBOOTSTRAP_ROOT="$1"

  echo "Bootstrapping live environment..."

  debootstrap "$RELEASE_BASE" "${DEBOOTSTRAP_ROOT}" "$RELEASE_MIRROR"

  mount_chroot "$DEBOOTSTRAP_ROOT"

  mkdir "${DEBOOTSTRAP_ROOT}/cdrom"
  mkdir "${DEBOOTSTRAP_ROOT}/boot/efi"

  mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf" "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup"
  echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" >"${DEBOOTSTRAP_ROOT}/etc/resolv.conf"

  chroot_env "$DEBOOTSTRAP_ROOT" apt update
  chroot_env "$DEBOOTSTRAP_ROOT" apt install -y software-properties-common
  chroot_env "$DEBOOTSTRAP_ROOT" add-apt-repository -y main
  chroot_env "$DEBOOTSTRAP_ROOT" add-apt-repository -y universe
  chroot_env "$DEBOOTSTRAP_ROOT" add-apt-repository -y multiverse
  chroot_env "$DEBOOTSTRAP_ROOT" add-apt-repository -y restricted

  if [[ ! -z "$ADDITIONAL_REPOSITORIES" ]]; then
    for PPA in $ADDITIONAL_REPOSITORIES; do
      echo "Adding apt repository ${PPA}"
      chroot_env "$DEBOOTSTRAP_ROOT" add-apt-repository -y "$PPA"
    done
  else
    echo "No additional apt repositories to add."
  fi

  # enabling source packages for advanced package search
  for file in "${DEBOOTSTRAP_ROOT}/etc/apt/sources.list" "${DEBOOTSTRAP_ROOT}/etc/apt/sources.list.d/"*; do
    sed -i '/deb-src/s/^# //' "$file"
  done

  chroot_env "$DEBOOTSTRAP_ROOT" apt update

  for SELECTION in "${DEBCONF_SELECTIONS[@]}"; do
    echo "$SELECTION" | chroot_env "$DEBOOTSTRAP_ROOT" debconf-set-selections
  done

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

  chroot_env "$DEBOOTSTRAP_ROOT" apt install -y ubuntu-desktop ubuntu-restricted-extras language-pack-${LANGUAGE_PACK} language-pack-gnome-${LANGUAGE_PACK} language-pack-${LANGUAGE_PACK}-base language-pack-gnome-${LANGUAGE_PACK}-base flatpak gnome-software-plugin-flatpak fwupd ntfs-3g casper ubiquity-casper initramfs-tools live-boot-initramfs-tools live-boot live-tools linux-generic packagekit locales grub2 grub-pc grub-efi-amd64-signed

  sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$KEYBOARD_LAYOUT'\"/g' "${DEBOOTSTRAP_ROOT}/etc/default/keyboard"
  chroot_env "$DEBOOTSTRAP_ROOT" /usr/sbin/update-locale LANG="${LANGUAGE}.UTF-8"

  echo "Installing additional packages"
  chroot_env "$DEBOOTSTRAP_ROOT" apt install -y $ADDITIONAL_PACKAGES
  chroot_env "$DEBOOTSTRAP_ROOT" apt purge -y $PACKAGE_REMOVAL

  chroot_env "$DEBOOTSTRAP_ROOT" apt autoremove -y
  chroot_env "$DEBOOTSTRAP_ROOT" apt clean
  chroot_env "$DEBOOTSTRAP_ROOT" rm -rf /var/cache/apt/* || true

  echo "Installing additional flatpaks..."

  # https://deb.li/bubblewrap
  sysctl kernel.unprivileged_userns_clone=1

  chroot_env "$DEBOOTSTRAP_ROOT" sh -c 'grep /usr/bin/bwrap /var/lib/dpkg/statoverride || dpkg-statoverride --update --add root root 0755 /usr/bin/bwrap'
  echo kernel.unprivileged_userns_clone=1 > "$DEBOOTSTRAP_ROOT/etc/sysctl.d/50-bubblewrap.conf"

  yes | bwrap_env "$DEBOOTSTRAP_ROOT" flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  bwrap_env "$DEBOOTSTRAP_ROOT" flatpak update --noninteractive --system -y || true

  for FLATPAK in $ADDITIONAL_FLATPAKS; do
    bwrap_env "$DEBOOTSTRAP_ROOT" flatpak install --noninteractive --system --or-update -y flathub "$FLATPAK"
  done
  bwrap_env "$DEBOOTSTRAP_ROOT" flatpak update --noninteractive --system -y || true

  sed -i -e 's/USERNAME=".*"/USERNAME="alpaka"/' -e 's/USERFULLNAME=".*"/USERFULLNAME="Jugend hackt Teilnehmer*in"/' -e 's/HOST=".*"/HOST="jugendhackt"/' "$DEBOOTSTRAP_ROOT/etc/casper.conf"

  mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup" "$DEBOOTSTRAP_ROOT/etc/resolv.conf"

  umount_chroot "$DEBOOTSTRAP_ROOT"

  if [[ ! -d $CACHE_PATH ]]; then
    mkdir "${CACHE_PATH}"
  fi

  mksquashfs "$DEBOOTSTRAP_ROOT" "${SQUASHFS_FILE}"
  echo "Keeping squashfs cached at ${SQUASHFS_FILE} for later use. Remove in order to clean up space."

  rm -rf "$DEBOOTSTRAP_ROOT"
}

function flash_usb() {
  DEVICE="${USB}"

  if [[ $USB == /dev/nvme* || $USB == /dev/loop* ]]; then
    DEVICE_BIOS="${DEVICE}p4"
    DEVICE_ESP="${DEVICE}p1"
    DEVICE_CDROM="${DEVICE}p2"
    DEVICE_CASPER="${DEVICE}p3"
  elif [[ $USB == /dev/sd* ]]; then
    DEVICE_BIOS="${DEVICE}4"
    DEVICE_ESP="${DEVICE}1"
    DEVICE_CDROM="${DEVICE}2"
    DEVICE_CASPER="${DEVICE}3"
  else
    echo "Device path $DEVICE unknown. Expected /dev/sdX, /dev/nvmeXnY or /dev/loopX."
    exit 1
  fi

  echo "Creating mount points..."

  USB_MOUNT="$1"
  SQUASHFS_TMP="$2"

	SQUASHFS_SIZE="$(du -s "${SQUASHFS_FILE}" | cut -f1)"

	PART_2_SIZE="$((500000 + SQUASHFS_SIZE))"

	echo "Preparing temporary files..."

	parted --script "$DEVICE" mklabel gpt
	sync "$DEVICE"

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
	) | gdisk "$DEVICE"

	parted --script "$DEVICE" set 4 bios_grub on

	sync "$DEVICE"

	echo "Bootstrapping filesystems..."

	yes | mkfs.msdos -n "ESP" "${DEVICE_ESP}"
	yes | mkfs.msdos -n "BIOS" "${DEVICE_BIOS}"
	mkfs.ext4 -F -L "Jugend hackt Live" "${DEVICE_CDROM}"
	mkfs.ext4 -F -L "casper-rw" "${DEVICE_CASPER}"

	tune2fs -O ^metadata_csum_seed "${DEVICE_CDROM}"
	tune2fs -O ^metadata_csum_seed "${DEVICE_CASPER}"

	mount "${DEVICE_CDROM}" "${USB_MOUNT}"

	echo "Copying live media"

	mkdir "${USB_MOUNT}/casper"
	cp "${SQUASHFS_FILE}" "${USB_MOUNT}/casper/filesystem.squashfs"

	echo "Patching bootloader config..."

	LINUX_TMP="$(mktemp -u)"

	unsquashfs -d "${LINUX_TMP}" "${SQUASHFS_FILE}" /boot

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
	linux	/casper/vmlinuz boot=casper persistent fsck.mode=skip noprompt locale="${LANGUAGE}.UTF-8" keyb="${KEYBOARD_LAYOUT}" kernel.unprivileged_userns_clone=1 quiet splash
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

	CDROM_TMP="${SQUASHFS_TMP}/cdrom"
	ESP_TMP="${SQUASHFS_TMP}/boot/efi"

	mkdir -p "${ESP_TMP}" || true
	mkdir -p "${CDROM_TMP}" || true

	mount -o ro "${USB_MOUNT}/casper/filesystem.squashfs" "${SQUASHFS_TMP}"

	mount_chroot "$SQUASHFS_TMP"
	mount "${DEVICE_ESP}" "${ESP_TMP}"
	mount "${DEVICE_CDROM}" "${CDROM_TMP}"

	chroot_env "${SQUASHFS_TMP}" /usr/sbin/grub-install --target=i386-pc --boot-directory="/cdrom/boot" "${USB}" || true
	chroot_env "${SQUASHFS_TMP}" /usr/sbin/grub-install --removable --target=x86_64-efi --no-nvram --uefi-secure-boot --boot-directory="/cdrom/boot" --efi-directory="/boot/efi"

	umount "${ESP_TMP}"
	umount "${CDROM_TMP}"
	umount_chroot "$SQUASHFS_TMP"
	umount "${SQUASHFS_TMP}"

	rm -rf "${SQUASHFS_TMP}"

	echo "Syncing drive..."

	sync "$USB"

	echo "Removing temporary files..."

	umount "$USB_MOUNT"

	rmdir "$USB_MOUNT"
}

if [[ ! -f "${SQUASHFS_FILE}" ]]; then

  if [[ "build" != "$STAGE" ]]; then
    echo "${SQUASHFS_FILE} not found. Please run first : $0 build"
    exit 1
  fi

  DEBOOTSTRAP_ROOT="$(mktemp -d)"

	build_squashfs "$DEBOOTSTRAP_ROOT"

	if [ "$?" -ne 0 ]; then
    echo -e "Error building squashfs.\n\nYou can check check $DEBOOTSTRAP_ROOT for details."
    umount_chroot_env "$DEBOOTSTRAP_ROOT"
    exit 1
  fi

else

	if [[ "flash" != "$STAGE" ]]; then
		echo "${SQUASHFS_FILE} already found. If you want to force a rebuild, manually delete this file."
		exit 1
	fi

	USB_MOUNT="$(mktemp -d)"
	SQUASHFS_TMP="$(mktemp -d)"

	flash_usb "$USB_MOUNT" "$SQUASHFS_TMP"

	if [ "$?" -ne 0 ]; then
    echo -e "Error flashing USB drive.\n\nPleas check $USB_MOUNT and $SQUASHFS_TMP for details."
    umount_chroot_env "$SQUASHFS_TMP"
    exit 1
  fi

fi

echo "Done."

exit
