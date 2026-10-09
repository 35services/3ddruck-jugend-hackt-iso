#!/usr/bin/env bash
# Copies the running Ubuntu system, e.g. booted from a USB stick, to an internal
# disk with an EFI partition (1) and a Linux partition (2), and makes it
# bootable as a separate machine with its own hostname.
#
# Usage, as root, one stage after the other:
#   ./clone-to-disk.sh prepare   erase and format the target partitions
#   ./clone-to-disk.sh copy      copy the system, can run while the system is in use
#   ./clone-to-disk.sh finish    copy again, then make it bootable and give it its own identity
#
# Settings, as environment variables:
#   TARGET_DISK   the disk to copy to (default: /dev/nvme0n1)
#   NEW_HOSTNAME  the hostname of the copy (default: druck-lenovo)

set -euo pipefail

STAGE="${1:-}"
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1}"
NEW_HOSTNAME="${NEW_HOSTNAME:-druck-lenovo}"
MNT=/mnt/clone

# NVMe and MMC partitions have a "p" before the number, e.g. nvme0n1p1
function partition() {
  if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
    echo "${TARGET_DISK}p$1"
  else
    echo "${TARGET_DISK}$1"
  fi
}

TARGET_ESP="$(partition 1)"
TARGET_ROOT="$(partition 2)"

function check_requirements() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root, e.g. with sudo"
    exit 1
  fi

  SOURCE_DISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
  if [[ "$SOURCE_DISK" == "$TARGET_DISK" ]]; then
    echo "$TARGET_DISK is the disk the system is running from"
    exit 1
  fi

  if [[ "$(lsblk -no PARTTYPENAME "$TARGET_ESP")" != "EFI System" ]]; then
    echo "$TARGET_ESP is not an EFI System partition"
    exit 1
  fi
  if [[ "$(lsblk -no PARTTYPENAME "$TARGET_ROOT")" != "Linux filesystem" ]]; then
    echo "$TARGET_ROOT is not a Linux filesystem partition"
    exit 1
  fi
}

function mount_target() {
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount "$TARGET_ROOT" "$MNT"
  mkdir -p "$MNT/boot/efi"
  mountpoint -q "$MNT/boot/efi" || mount "$TARGET_ESP" "$MNT/boot/efi"
}

# Copies everything on the root file system. Other file systems, like /proc,
# /run or /boot/efi, stay empty mount points. The stick's EFI files point at the
# stick, so grub-install writes new ones in finish. The swap file is recreated
# instead of copied. The lowest CPU and IO priority keeps other work, like an
# image build, fast. Exit code 24 means files vanished while copying, e.g.
# temporary Docker files, which is fine.
function copy_system() {
  mount_target
  ionice -c3 nice -n19 rsync -aAXH --numeric-ids --one-file-system --delete --info=progress2 \
    --exclude=/swap.img \
    --exclude='/boot/efi/*' \
    --exclude='/tmp/*' \
    --exclude='/var/tmp/*' \
    / "$MNT/" || [[ $? -eq 24 ]]
}

case "$STAGE" in
  "prepare")
    check_requirements

    if findmnt "$TARGET_ESP" > /dev/null || findmnt "$TARGET_ROOT" > /dev/null; then
      echo "A partition of $TARGET_DISK is mounted, please unmount it first"
      exit 1
    fi

    lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$TARGET_DISK"
    echo
    read -r -p "Erase everything on $TARGET_ESP and $TARGET_ROOT? Type ERASE to continue: " ANSWER
    if [[ "$ANSWER" != "ERASE" ]]; then
      echo "Cancelled"
      exit 1
    fi

    mkfs.fat -F 32 -n ESP "$TARGET_ESP"
    mkfs.ext4 -F -L "$NEW_HOSTNAME" "$TARGET_ROOT"
    mount_target
    echo "Formatted and mounted at $MNT. Next: $0 copy"
    ;;

  "copy")
    check_requirements
    copy_system
    echo "Copied. Copy again later with $0 copy, or finish with $0 finish"
    ;;

  "finish")
    check_requirements

    if command -v docker > /dev/null && [[ -n "$(docker ps -q)" ]]; then
      echo "Docker containers are running. Wait for them to finish, so their data is copied completely."
      exit 1
    fi

    echo "Copying the changes since the last copy..."
    copy_system

    echo "Creating the swap file..."
    fallocate -l "$(stat -c %s /swap.img)" "$MNT/swap.img"
    chmod 600 "$MNT/swap.img"
    mkswap "$MNT/swap.img" > /dev/null

    echo "Pointing /etc/fstab to the new partitions..."
    sed -i \
      -e "s/$(findmnt -no UUID /)/$(blkid -s UUID -o value "$TARGET_ROOT")/" \
      -e "s/$(findmnt -no UUID /boot/efi)/$(blkid -s UUID -o value "$TARGET_ESP")/" \
      "$MNT/etc/fstab"

    echo "Giving the copy its own identity as $NEW_HOSTNAME..."
    OLD_HOSTNAME="$(cat /etc/hostname)"
    echo "$NEW_HOSTNAME" > "$MNT/etc/hostname"
    sed -i "s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" "$MNT/etc/hosts"
    rm -f "$MNT/etc/machine-id"
    systemd-machine-id-setup --root="$MNT"
    rm -f "$MNT"/etc/ssh/ssh_host_*
    # both machines would use the same Tailscale identity and push each other off
    rm -rf "$MNT/var/lib/tailscale"/*

    echo "Installing the boot loader..."
    for DIR in dev proc sys run; do
      mount --rbind "/$DIR" "$MNT/$DIR"
      mount --make-rslave "$MNT/$DIR"
    done
    chroot "$MNT" ssh-keygen -A
    chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
    # fallback path for firmware that ignores the boot entries
    chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
    chroot "$MNT" update-initramfs -u -k all
    chroot "$MNT" update-grub

    echo
    echo "The boot loader looks for this root partition:"
    grep fs_uuid "$MNT/boot/efi/EFI/ubuntu/grub.cfg"
    echo "$TARGET_ROOT has UUID $(blkid -s UUID -o value "$TARGET_ROOT")"
    echo

    umount -R "$MNT"
    echo "Done. Shut down, remove the stick and start from $TARGET_DISK."
    echo "Then log in to Tailscale again with: sudo tailscale up"
    ;;

  *)
    sed -n '2,13p' "$0" | cut -c3-
    exit 1
    ;;
esac
