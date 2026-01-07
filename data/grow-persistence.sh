#!/usr/bin/env bash

set -e

PARTITION="$(readlink -f /dev/disk/by-label/Jugend-hackt-USB)"

for BLOCK in /sys/block/*; do
  DEVICE="$(basename "$BLOCK")"
  if [[ "$(basename "$PARTITION")" == "$DEVICE"* ]]; then
    echo "Identified root disk $DEVICE."
    growpart "/dev/$DEVICE" 3
    resize2fs "/dev/${DEVICE}3"
  fi
done

