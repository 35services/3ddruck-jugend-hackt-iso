#!/usr/bin/env bash
# Builds the image with Docker, tests it in QEMU and flashes it onto USB sticks,
# without further interaction. Run it as root from the repository folder, e.g. in
# a screen session, with the sticks' /dev/disk/by-id/usb-… paths:
#
#   sudo ./build-and-flash.sh /dev/disk/by-id/usb-…-0:0 /dev/disk/by-id/usb-…-0:0
#
# Everything on the sticks is erased. The build uses ../cache and ../tmp, like
# ISO_LOG.md, and replaces an existing image, since the cache name only depends
# on config, not on data/ or the script.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. with sudo"
  exit 1
fi

if [[ $# -eq 0 ]]; then
  sed -n '2,10p' "$0" | cut -c3-
  exit 1
fi

CACHE="$(realpath ../cache)"
TMP="$(realpath ../tmp)"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"

function step() {
  echo
  echo "=== $(date +%T) $*"
}

# Check the sticks first, so nothing runs for an hour and then fails on them
STICKS=()
for STICK in "$@"; do
  DEVICE="$(realpath "$STICK")"
  if [[ ! -b "$DEVICE" || "$(lsblk -dno TYPE "$DEVICE")" != "disk" ]]; then
    echo "$STICK is not a disk"
    exit 1
  fi
  if [[ "$(lsblk -dno TRAN "$DEVICE")" != "usb" ]]; then
    echo "$STICK ($DEVICE) is not a USB disk"
    exit 1
  fi
  if [[ "$DEVICE" == "$ROOT_DISK" ]]; then
    echo "$STICK ($DEVICE) is the disk the system runs from"
    exit 1
  fi
  STICKS+=("$STICK")
  echo "Stick: $DEVICE, $(lsblk -dno SIZE,MODEL "$DEVICE")"
done

# runs a stage of jugendhackt-iso.sh, with extra docker options before "--"
function docker_run() {
  local OPTIONS=()
  while [[ "$1" != "--" ]]; do
    OPTIONS+=("$1")
    shift
  done
  shift
  docker run --privileged -t --rm \
    -v "$PWD/config":/config \
    -v "$PWD/secrets":/secrets \
    -v "$CACHE":/var/cache/jugendhackt-iso \
    -v "$TMP":/var/tmp \
    "${OPTIONS[@]}" \
    jugendhackt-iso /jugendhackt-iso.sh "$@"
}

step "Removing the old image"
mkdir -p "$CACHE" "$TMP"
rm -fv "$CACHE"/*.erofs "$CACHE"/*.img "$CACHE"/*.sum

step "Building the Docker image"
docker build -t jugendhackt-iso .

step "Building the system"
docker_run -- build

step "Creating the USB image"
# the image stage needs the loop devices of /dev
docker_run -v /dev:/dev -- image
IMG="$(ls "$CACHE"/*.img)"
IMG_SIZE="$(stat -c %s "$IMG")"
cat "$CACHE"/*.sum

step "Testing the image in QEMU"
docker_run -- test uefi

for STICK in "${STICKS[@]}"; do
  DEVICE="$(realpath "$STICK")"
  if [[ "$(lsblk -dnbo SIZE "$DEVICE")" -lt "$IMG_SIZE" ]]; then
    echo "$DEVICE is smaller than the image"
    exit 1
  fi
done

step "Erasing and flashing ${#STICKS[@]} stick(s) in parallel"
PIDS=()
for STICK in "${STICKS[@]}"; do
  DEVICE="$(realpath "$STICK")"
  # a desktop may have mounted the stick's partitions automatically
  for PART in $(lsblk -lno NAME "$DEVICE" | tail -n +2); do
    umount "/dev/$PART" 2> /dev/null || true
  done
  wipefs -a "$DEVICE" > /dev/null
  dd if="$IMG" of="$STICK" bs=4M conv=fsync oflag=direct status=none &
  PIDS+=($!)
  echo "Flashing $DEVICE"
done
for PID in "${PIDS[@]}"; do
  wait "$PID"
done

step "Comparing the sticks with the image"
FAILED=0
for STICK in "${STICKS[@]}"; do
  DEVICE="$(realpath "$STICK")"
  if cmp -n "$IMG_SIZE" "$IMG" "$STICK"; then
    echo "OK: $DEVICE matches the image"
  else
    echo "FAILED: $DEVICE doesn't match the image"
    FAILED=1
  fi
done

step "Done"
exit $FAILED
