#!/usr/bin/env bash

set -e

STAGE=$1

function help () {
  echo "Bootstraps a persistent Debian-based live system on a USB stick"
  echo ""
  echo "1. Build a the cache for later bulk flash"
  echo "> jugendhackt-iso.sh build"
  echo ""
  echo "2. Create a disk image to flash on a USB drive"
  echo "> jugendhackt-iso.sh image"
  echo ""
  echo "3. (Optional) Interactively test your built image using QEMU"
  echo "> jugendhackt-iso.sh qemu (uefi|bios) [headless] [ci]"
  echo ""
  echo "4. (Optional) Automatically test your built image using QEMU"
  echo "> jugendhackt-iso.sh test (uefi|bios) [ci]"
  echo ""
  echo "Author: The one with the braid <info@braid.business>"
}

if [[ "--help" == "$STAGE" || "-h" == "$STAGE" || -z "$STAGE" ]]; then
  help
  exit 0
fi

function check_dependencies() {
  REQUIRED_LIBRARIES=" not found.\n\nPlease ensure the following packages are installed:\n\n- debootstrap (debootstrap)\n- sgdisk (gdisk)\n- mkfs.ext4 (e2fsprogs)\n- mkfs.msdos (dosfstools)\n- mkfs.erofs (erofs-utils)\n - udevadm (udev)\n - bwrap (bubblewrap)\n - flatpak (flatpak)\n - fallocate (util-linux)\n - expect (expect)\n - curl (curl)\n - unzip (unzip)"

  for COMMAND in debootstrap sgdisk mkfs.ext4 mkfs.msdos mkfs.erofs udevadm bwrap flatpak fallocate expect curl unzip; do
    if [[ ! -x "$(command -v $COMMAND)" ]]; then
      echo -e "${COMMAND}${REQUIRED_LIBRARIES}"
      exit 1
    fi
  done
}

function load_config () {
  if [[ ! -f config ]]; then
    echo "Please copy ./config.sample to ./config and adjust it to your needs"
    exit 1
  fi

  source "./config"

  # logins that must not be committed, see secrets.sample
  if [[ -f secrets ]]; then
    source "./secrets"
  fi

  # the version is the topmost released one in CHANGELOG.md, see CLAUDE.md
  if [[ ! -f CHANGELOG.md || ! -f .iso-name || ! -f .iso-version ]]; then
    echo "CHANGELOG.md, .iso-name or .iso-version is missing. In Docker, rebuild the image."
    exit 1
  fi
  ISO_VERSION="$(sed -n 's/^## \[\([0-9][0-9]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
  if [[ -z "$ISO_VERSION" ]]; then
    echo "CHANGELOG.md has no released version like \"## [3] - 2026-10-12\""
    exit 1
  fi
  if [[ "$(cat .iso-version)" != "$ISO_VERSION" ]]; then
    echo ".iso-version contains $(cat .iso-version), but the latest version in CHANGELOG.md is ${ISO_VERSION}. Please update .iso-version."
    exit 1
  fi
  CHANGELOG_URL="https://github.com/35services/3ddruck-jugend-hackt-iso/blob/3d-druck-ag/CHANGELOG.md"

  ISO_NAME="$(cat .iso-name)"
  if [[ ! "$ISO_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo ".iso-name must only contain lowercase letters, digits and dashes, as it names the image file"
    exit 1
  fi

  IDENTIFIER="${ISO_NAME}-v${ISO_VERSION}"
  CACHE_PATH="${CACHE_PATH-/var/cache/jugendhackt-iso}"
  EROFS_FILE="${CACHE_PATH}/${IDENTIFIER}.erofs"
  IMAGE_FILE="${CACHE_PATH}/${IDENTIFIER}.img"

  if [[ -z "$KEYBOARD_LAYOUT" ]]; then
    KEYBOARD_LAYOUT="us"
  fi

  if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE="UTC"
  fi

  if [[ -z "$LANGUAGE" ]]; then
    LANGUAGE="en_US"
  fi

  if [[ -z "$TASK_LANGUAGES" ]]; then
    TASK_LANGUAGES="english"
  fi
}

function check_root () {
  if [[ $EUID != 0 ]]; then
    echo "Please run this script as root in order to create a system image."
    exit 1
  fi
}

function check_non_root () {
  if [[ $EUID == 0 ]]; then
    echo "Please run this script without root privileges in order to access KVM."
    exit 1
  fi
}

function mount_chroot() {
  CHROOT="$1"

  # self-bind in order to fix "bwrap: Failed to make master / slave: Invalid argument"
  # see https://github.com/flatpak/flatpak/issues/703#issuecomment-293250243
  mount --bind "${CHROOT}" "${CHROOT}"

  mount proc "$CHROOT/proc" -t proc -o nosuid,noexec,nodev
  mount sys "$CHROOT/sys" -t sysfs -o nosuid,noexec,nodev,ro
  # missing CAP_SYS_ADMIN for udevfs and devtmpfs so binding
  mount --bind /dev "$CHROOT/dev"
  mount tmp "$CHROOT/tmp" -t tmpfs -o mode=1777,strictatime,nodev,nosuid
}

function umount_chroot() {
  CHROOT="$1"

  umount "$CHROOT/tmp"
  umount "$CHROOT/dev"
  umount "$CHROOT/sys"
  umount "$CHROOT/proc"

  umount "$CHROOT"
}

function mount_grub_chroot() {
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

function umount_grub_chroot() {
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

# Runs flatpak from the build environment on the new system's installation.
# Running it inside the new system with bwrap doesn't work: flatpak starts bwrap
# itself, e.g. for triggers and extra data, and bwrap can't create namespaces
# inside another bwrap ("bwrap: Creating new namespace failed").
flatpak_env () {
  FLATPAK_SYSTEM_DIR="$1/var/lib/flatpak" flatpak "${@:2}"
}


function build_erofs() {
  DEBOOTSTRAP_ROOT="$1"
  
  if [[ "$(sysctl -b kernel.unprivileged_userns_clone)" -ne "1" ]]; then
	# https://deb.li/bubblewrap
  	echo "You must set sysctl kernel.unprivileged_userns_clone=1"
	exit 1
  fi

  echo "Bootstrapping live environment..."

  debootstrap "$RELEASE_BASE" "${DEBOOTSTRAP_ROOT}" "$RELEASE_MIRROR"

  mount_chroot "$DEBOOTSTRAP_ROOT"

  mkdir "${DEBOOTSTRAP_ROOT}/cdrom"
  mkdir "${DEBOOTSTRAP_ROOT}/boot/efi"

  mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf" "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup"
  echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112\nnameserver 2620:fe::fe\nnameserver 2620:fe::9" >"${DEBOOTSTRAP_ROOT}/etc/resolv.conf"

  if [ ! -d "$DEBOOTSTRAP_ROOT/etc/apt/sources.list.d" ]; then
    mkdir "$DEBOOTSTRAP_ROOT/etc/apt/sources.list.d"
  fi

  cp data/debian.sources "$DEBOOTSTRAP_ROOT/etc/apt/sources.list.d/debian.sources"

  if [ -f "$DEBOOTSTRAP_ROOT/etc/apt/sources.list" ]; then
    rm "$DEBOOTSTRAP_ROOT/etc/apt/sources.list"
  fi
  
  chroot_env "$DEBOOTSTRAP_ROOT" apt update

  for SELECTION in "${DEBCONF_SELECTIONS[@]}" \
    "firmware-ipw2x00 firmware-ipw2x00/license/accepted boolean true"; do
    echo "$SELECTION" | chroot_env "$DEBOOTSTRAP_ROOT" debconf-set-selections
  done

  for task in $TASK_LANGUAGES; do
    TASK_STRING="$TASK_STRING task-$task"
    if [[ "$task" != "english" ]]; then
      TASK_STRING="$TASK_STRING task-$task-desktop"
    fi
  done

  chroot_env "$DEBOOTSTRAP_ROOT" apt install -y gnome flatpak gnome-software-plugin-flatpak fwupd apt-transport-https hunspell $TASK_STRING ntfs-3g initramfs-tools live-boot-initramfs-tools live-boot live-config live-task-non-free-firmware-pc live-tools linux-image-amd64 packagekit locales grub2 grub-pc grub-efi-amd64-signed shim-signed keyboard-configuration systemd-timesyncd bash-completion e2fsprogs cloud-guest-utils erofs-utils

  echo "Installing additional packages"
  chroot_env "$DEBOOTSTRAP_ROOT" apt install -y $ADDITIONAL_PACKAGES
  chroot_env "$DEBOOTSTRAP_ROOT" apt purge -y $PACKAGE_REMOVAL

  if [[ ${#SSH_AUTHORIZED_KEYS[@]} -gt 0 ]]; then
    echo "Setting up SSH access..."
    chroot_env "$DEBOOTSTRAP_ROOT" apt install -y openssh-server
    # live-config generates unique host keys on each stick's first boot
    rm -f "$DEBOOTSTRAP_ROOT"/etc/ssh/ssh_host_*
    printf '%s\n' "${SSH_AUTHORIZED_KEYS[@]}" > "$DEBOOTSTRAP_ROOT/etc/ssh/jugendhackt_authorized_keys"
    chmod 644 "$DEBOOTSTRAP_ROOT/etc/ssh/jugendhackt_authorized_keys"
    cp data/sshd_config.conf "$DEBOOTSTRAP_ROOT/etc/ssh/sshd_config.d/50-jugendhackt-iso.conf"
    chmod 644 "$DEBOOTSTRAP_ROOT/etc/ssh/sshd_config.d/50-jugendhackt-iso.conf"
  fi

  if compgen -G "data/desktop/*" > /dev/null; then
    echo "Adding files to the desktop..."
    chroot_env "$DEBOOTSTRAP_ROOT" apt install -y gnome-shell-extension-desktop-icons-ng xdg-user-dirs
    mkdir -p "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop"
    cp -r data/desktop/. "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop/"
    printf 'Snapmaker-Konto der 3D-Druck-AG\n===============================\n\nBenutzer: %s\nPasswort: %s\n' \
      "$SNAPMAKER_USERNAME" "$SNAPMAKER_PASSWORD" > "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop/snapmaker-konto.txt"
    printf 'MakerWorld-Konto der 3D-Druck-AG\n================================\n\nBenutzer: %s\nPasswort: %s\n' \
      "$MAKERWORLD_USERNAME" "$MAKERWORLD_PASSWORD" > "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop/makerworld-konto.txt"
    printf 'Version dieses USB-Sticks\n=========================\n\nName: %s\nVersion: %s\nBau gestartet: %s\n\nWas sich in den Versionen geändert hat, steht im Changelog:\n%s\n' \
      "$ISO_NAME" "$ISO_VERSION" "$BUILD_STARTED" "$CHANGELOG_URL" > "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop/version.txt"
    # read-only, so they aren't changed by accident; cp in copy-desktop-files.sh keeps the mode
    find "$DEBOOTSTRAP_ROOT/usr/share/jugendhackt-iso/desktop" -type f -name '*.txt' -exec chmod 444 {} +
    cp data/copy-desktop-files.sh "$DEBOOTSTRAP_ROOT/usr/local/bin/copy-desktop-files.sh"
    chmod 755 "$DEBOOTSTRAP_ROOT/usr/local/bin/copy-desktop-files.sh"
    cp data/copy-desktop-files.desktop "$DEBOOTSTRAP_ROOT/etc/xdg/autostart/copy-desktop-files.desktop"
    cp data/90-jugendhackt-iso.gschema.override "$DEBOOTSTRAP_ROOT/usr/share/glib-2.0/schemas/90-jugendhackt-iso.gschema.override"
    chroot_env "$DEBOOTSTRAP_ROOT" glib-compile-schemas /usr/share/glib-2.0/schemas
  fi
  chroot_env "$DEBOOTSTRAP_ROOT" apt autoremove -y
  chroot_env "$DEBOOTSTRAP_ROOT" apt clean
  chroot_env "$DEBOOTSTRAP_ROOT" rm -rf /var/cache/apt/* || true

  echo "Installing additional flatpaks..."

  chroot_env "$DEBOOTSTRAP_ROOT" sh -c 'grep /usr/bin/bwrap /var/lib/dpkg/statoverride || dpkg-statoverride --update --add root root 0755 /usr/bin/bwrap'
  echo kernel.unprivileged_userns_clone=1 > "$DEBOOTSTRAP_ROOT/etc/sysctl.d/50-bubblewrap.conf"

  yes | flatpak_env "$DEBOOTSTRAP_ROOT" remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak_env "$DEBOOTSTRAP_ROOT" update --noninteractive --system -y || true

  for FLATPAK in $ADDITIONAL_FLATPAKS; do
    flatpak_env "$DEBOOTSTRAP_ROOT" install --noninteractive --system --or-update -y flathub "$FLATPAK"
  done

  for BUNDLE_URL in $ADDITIONAL_FLATPAK_BUNDLES; do
    curl -fL -o "$DEBOOTSTRAP_ROOT/tmp/bundle.flatpak" "$BUNDLE_URL"
    flatpak_env "$DEBOOTSTRAP_ROOT" install --noninteractive --system -y --bundle "$DEBOOTSTRAP_ROOT/tmp/bundle.flatpak"
    rm "$DEBOOTSTRAP_ROOT/tmp/bundle.flatpak"
  done
  flatpak_env "$DEBOOTSTRAP_ROOT" update --noninteractive --system -y || true

  # app menu entries in data/applications replace the ones of installed apps,
  # since the user's entries take precedence over Flatpak's
  mkdir -p "$DEBOOTSTRAP_ROOT/etc/skel/.local/share/applications"
  cp data/applications/*.desktop "$DEBOOTSTRAP_ROOT/etc/skel/.local/share/applications/"

  echo "Installing additional Inkscape extensions..."

  INKSCAPE_EXTENSIONS_DIR="$DEBOOTSTRAP_ROOT/etc/skel/.config/inkscape/extensions"
  for EXTENSION_URL in $INKSCAPE_EXTENSION_ZIPS; do
    EXTENSION_TMP="$(mktemp -d)"
    curl -fL -o "$EXTENSION_TMP/extension.zip" "$EXTENSION_URL"
    unzip -q "$EXTENSION_TMP/extension.zip" -d "$EXTENSION_TMP/extracted"
    # copy the contents of a single top-level folder, not the folder itself
    EXTENSION_SOURCE="$EXTENSION_TMP/extracted"
    EXTENSION_ENTRIES=("$EXTENSION_SOURCE"/*)
    if [[ ${#EXTENSION_ENTRIES[@]} -eq 1 && -d "${EXTENSION_ENTRIES[0]}" ]]; then
      EXTENSION_SOURCE="${EXTENSION_ENTRIES[0]}"
    fi
    mkdir -p "$INKSCAPE_EXTENSIONS_DIR"
    cp -r "$EXTENSION_SOURCE"/. "$INKSCAPE_EXTENSIONS_DIR/"
    rm -rf "$EXTENSION_TMP"
  done

  cp data/live.conf "$DEBOOTSTRAP_ROOT/etc/live/config.conf"
  cp data/grow-persistence.sh "$DEBOOTSTRAP_ROOT/usr/local/bin/grow-persistence.sh"
  chmod 744 "$DEBOOTSTRAP_ROOT/usr/local/bin/grow-persistence.sh"
  cp data/grow-persistence.service "$DEBOOTSTRAP_ROOT/etc/systemd/system/grow-persistence.service"
  chmod 664 "$DEBOOTSTRAP_ROOT/etc/systemd/system/grow-persistence.service"
  ln -s /etc/systemd/system/grow-persistence.service "$DEBOOTSTRAP_ROOT/etc/systemd/system/multi-user.target.wants/grow-persistence.service"

  # support for erofs
  echo "erofs" >> "$DEBOOTSTRAP_ROOT/etc/initramfs-tools/modules"
  chroot_env "$DEBOOTSTRAP_ROOT" /usr/sbin/update-initramfs -u -k all

  mv "$DEBOOTSTRAP_ROOT/etc/resolv.conf.backup" "$DEBOOTSTRAP_ROOT/etc/resolv.conf"

  umount_chroot "$DEBOOTSTRAP_ROOT"

  if [[ ! -d $CACHE_PATH ]]; then
    mkdir "${CACHE_PATH}"
  fi

  # suggestions: https://sigma-star.at/blog/2022/07/erofs-erofs/
  mkfs.erofs -zlz4hc "${EROFS_FILE}" "$DEBOOTSTRAP_ROOT" > /dev/null
  echo "Keeping erofs cached at ${EROFS_FILE} for later use. Remove in order to clean up space."

  rm -rf "$DEBOOTSTRAP_ROOT"
}

function disk_image() {
  EROFS_SIZE="$(du -s "${EROFS_FILE}" | cut -f1)"
  PART_2_SIZE="$((1000000 + EROFS_SIZE))"

  IMAGE_SIZE="$((PART_2_SIZE * 1000))"

  echo "Creating loop device..."

  fallocate -l "$((IMAGE_SIZE + 1000000000))" "${IMAGE_FILE}"
  losetup -fP "${IMAGE_FILE}"

  OUTPUT="$(losetup -a | grep "${IMAGE_FILE}")"
  SPLIT=(${OUTPUT//:/ })

  DEVICE=${SPLIT[0]}

  DEVICE_BIOS="${DEVICE}p4"
  DEVICE_ESP="${DEVICE}p1"
  DEVICE_CDROM="${DEVICE}p2"
  DEVICE_PERSISTENCE="${DEVICE}p3"

  sleep 10 # Wait for loop device to settle

  echo "Partitioning disk..."

  # create empty partition table
  sgdisk "$DEVICE" -o
  # create GRUB partition in the first 2048 sectors
  sgdisk "$DEVICE" -a 1 --new 4:34:2047 --typecode 4:ef02
  # create ESP
  sgdisk "$DEVICE" --new 1::+512M --typecode 1:ef00
  # create live boot partition
  sgdisk "$DEVICE" --new "2::+${PART_2_SIZE}K" --attributes 2:set:63
  # create persistence partition with SD_GPT_FLAG_GROWFS flag
  sgdisk "$DEVICE" --new 3::0 --attributes 3:set:59

  sync "$DEVICE"

  sleep 10 # Wait for sync to complete

  partprobe -s "$DEVICE" # Ensure partitions are loaded

  sleep 10 # Wait for partitions to load

  if [ ! -e "${DEVICE_BIOS}" ] || [ ! -e "${DEVICE_ESP}" ] || [ ! -e "${DEVICE_CDROM}" ] || [ ! -e "${DEVICE_PERSISTENCE}" ]; then
    MAJOR=$(cat /proc/devices | grep blkext | cut -d" " -f1)
    mknod "${DEVICE_ESP}" b "${MAJOR}" 1
    mknod "${DEVICE_CDROM}" b "${MAJOR}" 2
    mknod "${DEVICE_PERSISTENCE}" b "${MAJOR}" 5
    mknod "${DEVICE_BIOS}" b "${MAJOR}" 6
  fi

  echo "Bootstrapping filesystems..."

  yes | mkfs.msdos -n "ESP" "${DEVICE_ESP}"
  yes | mkfs.msdos -n "BIOS" "${DEVICE_BIOS}"
  mkfs.ext4 -F -L "BOOT" "${DEVICE_CDROM}"
  mkfs.ext4 -F -L "Jugend-hackt-USB" "${DEVICE_PERSISTENCE}"

  tune2fs -O ^metadata_csum_seed "${DEVICE_CDROM}"
  tune2fs -O ^metadata_csum_seed "${DEVICE_PERSISTENCE}"

  echo "Creating mount points..."

  LIVE_MOUNT="$1"
  EROFS_TMP="$2"

  PERSISTENCE_TMP="$(mktemp -p /var/tmp -d)"

  mount "${DEVICE_PERSISTENCE}" "${PERSISTENCE_TMP}"
  cp data/persistence.conf "${PERSISTENCE_TMP}"

  umount "${PERSISTENCE_TMP}"
  rmdir "${PERSISTENCE_TMP}"

  echo "Copying live media..."

  mount "${DEVICE_CDROM}" "${LIVE_MOUNT}"

  mkdir "${LIVE_MOUNT}/.live"
  chmod 700 "${LIVE_MOUNT}/.live"

  # live-boot enforces the file name bespite actually supporting erofs
  cp "${EROFS_FILE}" "${LIVE_MOUNT}/.live/filesystem.squashfs"

  echo "Copying kernel and initramfs..."

  mount -o ro "${EROFS_FILE}" "${EROFS_TMP}"
  mount_grub_chroot "$EROFS_TMP"

  cp "${EROFS_TMP}/vmlinuz" "${LIVE_MOUNT}/.live/vmlinuz"
  cp "${EROFS_TMP}/initrd.img" "${LIVE_MOUNT}/.live/initrd.img"

  echo "Installing grub..."

  mkdir -p "${LIVE_MOUNT}/.boot/grub"
  chmod 700 "${LIVE_MOUNT}/.boot"

  cp data/grub.cfg "${LIVE_MOUNT}/.boot/grub/grub.cfg"

  CDROM_TMP="${EROFS_TMP}/cdrom"
  ESP_TMP="${EROFS_TMP}/boot/efi"

  mkdir -p "${ESP_TMP}" || true
  mkdir -p "${CDROM_TMP}" || true

  mount "${DEVICE_ESP}" "${ESP_TMP}"
  mount "${DEVICE_CDROM}" "${CDROM_TMP}"

  chroot_env "${EROFS_TMP}" /usr/sbin/grub-install --target=i386-pc --boot-directory="/cdrom/.boot" --force "${DEVICE}"
  chroot_env "${EROFS_TMP}" /usr/sbin/grub-install --removable --target=x86_64-efi --no-nvram --uefi-secure-boot --boot-directory="/cdrom/.boot" --efi-directory="/boot/efi"

  umount "${ESP_TMP}"
  umount "${CDROM_TMP}"
  umount_grub_chroot "$EROFS_TMP"
  umount "${EROFS_TMP}"

  rm -rf "${EROFS_TMP}"

  echo "Syncing drive..."

  sync "$DEVICE"

  echo "Removing temporary files..."

  umount "$LIVE_MOUNT"

  losetup -d "${DEVICE}"

  rmdir "$LIVE_MOUNT"
  sha256sum "$IMAGE_FILE" > "${CACHE_PATH}/${IDENTIFIER}.sum"
  echo "SHA256 Sum:"
  cat "${CACHE_PATH}/${IDENTIFIER}.sum"
  echo ""

  echo -e "You can find the disk image at: ${IMAGE_FILE}\n\nPlease use a tool link Etcher or the dd command to flash it to your USB drive."
}

function qemu_boot () {
  if [[ ! -x "$(command -v qemu-system-x86_64)" ]]; then
    echo -e "QEMU is not installed.\nPlease install the qemu-system-x86 package."
    exit 1
  fi

  if ! id -nG "$(whoami)" | grep -qw kvm; then
    echo -e "You need to be part of the kvm group in order to boot the disk image using QEMU.\nPlease first run:\nsudo usermod -aG kvm \$USER\nnewgrp kvm"
    exit 1
  fi

  DISPLAY="-nographic"
  if [[ "$HEADLESS" != "headless" ]]; then
    check_non_root
    DISPLAY="-serial stdio -display gtk -device VGA,vgamem_mb=128"
  fi

  QEMU_MACHINE="-machine type=q35"
  QEMU_MEMORY="-m 4G"
  QEMU_NETWORK=""
  QEMU_CPU=""
  if [[ "$GITLAB_CI" != "ci" ]]; then
    QEMU_MACHINE="-machine type=q35,accel=kvm"
    QEMU_MEMORY="-m 8G"
    QEMU_NETWORK="-device virtio-net,netdev=vmnic -netdev user,id=vmnic"
    QEMU_CPU="-cpu host"
  fi

  case "$MODE" in
    "uefi")
      CODE_PREDICTS="/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd"
      for f in ${CODE_PREDICTS}; do
        if [[ -f "$f" ]]; then
          CODE_FD="$f"
        fi
      done

      VARS_PREDICTS="/usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/x64/OVMF_VARS.4m.fd"
      for f in ${VARS_PREDICTS}; do
        if [[ -f "$f" ]]; then
          VARS_FD="$f"
        fi
      done

      if [[ -z "$CODE_FD" || -z "$VARS_FD" ]]; then
        echo -e "Could not find any matching UEFI files.\nPlease install the ovmf package."
        exit 1
      fi

      BIOS_FD_FLAGS="-drive if=pflash,format=raw,readonly=on,file=${CODE_FD} -drive if=pflash,format=raw,file=${VARS_FD}"
      ;;
    "bios")
      BIOS_FD_FLAGS=""
  esac

  qemu-system-x86_64 \
    $QEMU_MACHINE \
    $QEMU_MEMORY \
    $QEMU_CPU \
    -smp $(nproc) \
    $DISPLAY \
    $QEMU_NETWORK \
    -snapshot -drive file="$IMAGE_FILE" \
    $BIOS_FD_FLAGS
}

function qemu_test () {
  expect -f - <<EOF
    set timeout 600
    spawn ./jugendhackt-iso.sh qemu $MODE headless $GITLAB_CI
    expect {
         "Press enter to boot the selected OS" {
             sleep 5
             send "\n"
             exp_continue
         }
         "login: " {
             sleep 1
             send "druck\n"
             exp_continue
         }
         "Passwort: " {
             sleep 1
             send "live\n"
             exp_continue
         }
         ":~$ " {
             sleep 1
             send "sudo shutdown -h now\n"
             exp_continue
         }
         "qemu-system-x86_64: " {
            exit 2
         }
         timeout {
             exit 1
         }
         eof {
             exit
         }
    }
EOF
  if [ "$?" -ne 0 ]; then
      echo -e "Test test failed"
      exit 1
  fi
  echo -e "Test passed"
}

#check_dependencies
load_config

case "${STAGE}" in
  "build")
    check_root

    if [[ -z "$SNAPMAKER_USERNAME" || -z "$SNAPMAKER_PASSWORD" ]]; then
      echo "Please copy ./secrets.sample to ./secrets and set SNAPMAKER_USERNAME and SNAPMAKER_PASSWORD to the login of the AG's Snapmaker account"
      exit 1
    fi

    if [[ -z "$MAKERWORLD_USERNAME" || -z "$MAKERWORLD_PASSWORD" ]]; then
      echo "Please copy ./secrets.sample to ./secrets and set MAKERWORLD_USERNAME and MAKERWORLD_PASSWORD to the login of the AG's MakerWorld account"
      exit 1
    fi

    if [[ -f "${EROFS_FILE}" ]]; then
      echo "${EROFS_FILE} already found. If you want to force a rebuild, manually delete this file."
      exit 1
    fi
    BUILD_STARTED="$(TZ=Europe/Berlin date '+%d.%m.%Y %H:%M %Z')"
    echo "Building ${ISO_NAME} version ${ISO_VERSION}, started ${BUILD_STARTED}"
    DEBOOTSTRAP_ROOT="$(mktemp -p /var/tmp -d)"

    build_erofs "$DEBOOTSTRAP_ROOT"

    if [ "$?" -ne 0 ]; then
      echo -e "Error building erofs.\n\nYou can check check $DEBOOTSTRAP_ROOT for details."
      umount_chroot "$DEBOOTSTRAP_ROOT"
      exit 1
    fi
    ;;
  "image")
    check_root

    if [[ ! -f "${EROFS_FILE}" ]]; then
      echo "${EROFS_FILE} not found. Please run first : $0 build"
      exit 1
    fi

    LIVE_MOUNT="$(mktemp -p /var/tmp -d)"
    EROFS_TMP="$(mktemp -p /var/tmp -d)"

    disk_image "$LIVE_MOUNT" "$EROFS_TMP"

    if [ "$?" -ne 0 ]; then
      echo -e "Error creating USB image.\n\nPleas check $LIVE_MOUNT and $EROFS_TMP for details."
      umount_chroot "$EROFS_TMP"
      exit 1
    fi
    ;;
  "qemu")
    if [[ ! -f "${IMAGE_FILE}" ]]; then
      echo "${IMAGE_FILE} not found. Please run first : $0 image"
      exit 1
    fi

    MODE="$2"
    HEADLESS="$3"
    GITLAB_CI="$4"

    if [[ "$MODE" != "uefi" && "$MODE" != "bios" ]]; then
      help
      exit 1
    fi

    if [[ "$HEADLESS" != "" && "$HEADLESS" != "headless" ]]; then
      help
      exit 1
    fi

    if [[ "$GITLAB_CI" != "" && "$GITLAB_CI" != "ci" ]]; then
      help
      exit 1
    fi

    qemu_boot
    ;;
  "test")
    MODE="$2"
    GITLAB_CI="$3"

    if [[ "$MODE" != "uefi" && "$MODE" != "bios" ]]; then
      help
      exit 1
    fi

    if [[ "$GITLAB_CI" != "" && "$GITLAB_CI" != "ci" ]]; then
      help
      exit 1
    fi

    qemu_test
  ;;
  *)
    help
    exit 1
    ;;
esac

echo "Done."

exit

