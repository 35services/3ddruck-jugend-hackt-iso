# jugendhackt-iso.sh

**Please note:** This project lives on https://git.alpaka.space/aic/jugendhackt-iso.
The mirror on https://gitlab.com/Jugendhackt/jugendhackt-iso is no longer maintained.

Bootstraps a persistent Ubuntu-based live system on a USB stick.

## Features

- make Ubuntu persistent on your USB
- apply a sharable configuration via a single config file
- patch installed APT and Flatpak packages
- remove Snapd
- cache patched system in order to speed up further USBs
- supports Austrian German *<3 Jh Linz, love you*
- supports Swiss keyboard layout *<3 Jh Zurich, love you*

## Usage

### Prepare the configuration

```shell
## setup before first run

# copy config.sample to config in the same directory
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
# 
# E.g. for Events in Austria, change LANGUAGE to "de_AT" <3
# 
# IMPORTANT : check the latest Ubuntu *daily* release and adjust the RELEASE_BASE variable using the following command :
# 
# $ wget -qO- http://archive.ubuntu.com/ubuntu/dists/devel/Release | awk -F ': ' '$1 == "Codename" { print $2; exit }'
nano config

```

### Build using Docker

```shell
# install Docker in case you didn't do so before
# 
# e.g. on Ubuntu, execute : 
# $ sudo apt install docker.io
# $ sudo usermod -aG docker $USER
# $ newgrp docker

# once create a build cache for the current configuration
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh build

# specify the USB device to use. Check e.g. your Disk Utility to find out the path to the device
export USB_DRIVE=/dev/sdX

# run the script with access to all the resources it needs and flash the image onto the USB drive
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    -v "/dev":"/dev" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh flash $USB_DRIVE
```

### Flash multiple sticks at once using Docker

```shell
# pull the most recent docker image
docker pull registry.git.alpaka.space/aic/jugendhackt-iso:main

# once build the cache
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh build

# flash image onto all USB drives
# IMPARTANT: replace the list of /dev/sdX with all the drives you want to flash
for USB_DRIVE in /dev/sdb /dev/sdc /dev/sdd /dev/sdN; do
    docker run --privileged -d --rm \
        -v "$(pwd)/config":"/config" \
        -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
        -v "/dev":"/dev" \
        registry.git.alpaka.space/aic/jugendhackt-iso:main \
        /jugendhackt-iso.sh flash $USB_DRIVE
done

# check whether build finished
docker ps

# repeat this command until you see no more running container with the jugendhackt-iso container
docker ps

# once all containers stopped, you can unplug all USB drives and repeat the for loop with your new batch
```

### Standalone using system libraries

The script will check all dependencies and tell you how to install them.

```shell
# create build cache
sudo ./jugendhackt-iso.sh build

# replace <usb-device> with the device path of your USB drive, e.g. /dev/sdb
sudo ./jugendhackt-iso.sh flash <usb-device>
```

The environment variable `CACHE_PATH` controls where the resulting squashfs image will be stored and read from. If unset, it will default to `/var/cache/jugendhackt-iso`.

### Build on AArch64 / Apple Silicon / Raspberry Pi

As of now, it's not possible to build on AArch64 since we need to execute native binaries for amd64 in order to build the sticks for amd64. My past attempts using qemu-binfmt were not successful.

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

Author: The one with the braid <info@braid.business>
