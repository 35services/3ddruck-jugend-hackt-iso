# jugendhackt-iso.sh

Bootstraps a persistent Ubuntu-based live system on a USB stick.

## Features

- make Ubuntu persistent on your USB
- apply a sharable configuration via a single config file
- patch installed APT and Flatpak packages
- remove Snapd
- cache patched system in order to speed up further USBs
- supports Austrian German *<3 Jh Linz, love you*

## Usage

```shell
## setup before first run

# copy config.sample to config
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
nano config

## now create the sticks

# replace <usb-device> with the device path of your USB drive, e.g. /dev/sdb
jugendhackt-iso.sh <usb-device>
```

## Functionality

The jugendhackt-iso script passes two general stages :

1. boostrap a base system according to a config file or use a cached version
2. copy the base system on a USB drive, make it bootable, persistent and Secure Boot compatible

The first stage uses `deboostrap` in order to boostrap a Ubuntu base system. Naxt, PPAs, packages and flatpaks are installed according to the configuration and locale settings are applied.

Once the bootstrap is done, the compressed base system is stored in `/var/cache/jugendhackt-iso` in order to refactor it for the next use of the same configuration.

In case the script finds a cache present for the used config file, the entire step is skipped.

The second stage populates the available system on the specified stick. It is therefore completely formatted with four partitions being created : a BIOS grub partition for legacy boot, an EFI system partition for UEFI boot, a root partition containing the bootloader, the kernel and the compressed system as well as an empty partition used for persistance.

Once all this data is populated, the script syncs the USB drive and you can proceed with the next ones.

## Legal

This project was written for [Jugend hackt](https://jugendhackt.org), an Austrian, German and Swiss project getting youth closer to ethical technology. This project is not officially affiliated with Jugend hackt.

License: [EUPL-1.2](LICENSE)

Author: The one with the braid <the-one@with-the-braid.cf>
