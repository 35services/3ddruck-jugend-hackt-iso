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

### Prepare the confuguration

```shell
## setup before first run

# copy config.sample to config
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
# 
# E.g. for Events in Austria, change LANGUAGE to "de_AT" <3
# 
# IMPORTANT : check the latest Ubuntu *daily* release and adjust the RELEASE_BASE variable
nano config

```

### Build using Docker

```shell
# install Docker in case you didn't do so before
# 
# e.g. on Ubuntu, execute : 
# $ sudo apt install docker.io

# build the helper Docker image containing all the toolchain
docker build -t jugendhackt-iso:latest .

# alternatively, if you are familiar with Docker buildx, you can allso use the following command in order to use buildx to build the container
# $ docker buildx build -t jugendhackt-iso:latest .

# run the script with access to all the resources it needs

export USB_DRIVE=/dev/sdX # specify the USB device to use. Check e.g. your Disk Utility to find out the path to the device
docker run --privileged -ti --rm \
    -v ./config:/config \ # we need the config in the container
    -v ./cache:/var/cache/jugendhackt-iso \ # we use this cache to peed up builds
    -v "$USB_DRIVE":"$USB_DRIVE" \ # we need to pass over access to the USB drive we found
    jugendhackt-iso:latest /jugendhackt-iso.sh $USB_DRIVE # run the script with the specified USB drive

```

### Standalone using system libraries

The script will check all dependencies and tell you how to install them.

```shell
# replace <usb-device> with the device path of your USB drive, e.g. /dev/sdb
sudo ./jugendhackt-iso.sh <usb-device>

```

### Build on aarch64 / Apple silicon using Docker buildx

To regular users using normal mainstream processors, this section is not relevant. The following hints only apply to users using Apple silicon (Apple M2, Apple M2) or other aarch64 devices (e.g. the ThinkPad X13s).

The Dockerfile easily builds using [docker buildx](https://github.com/docker/buildx) which supports cross-arch builds. I personally develop on a Snapdragon 8cx Gen 3, and apart from som performance loss, it works very well.

Please follow the docs of Docker buildx and install it.

```shell
# install QEMU binfmt for cross-arch execution
docker run --privileged -d --name binfmt --rm tonistiigi/binfmt --install all

# build the Docker conainer for amd64
docker buildx build --platform linux/x86_64 -t jugendhackt-iso:latest .

# use the Docker image cross-arch to run the script
docker run \
    --platform linux/x86_64 \ # specify to use amd64 for execution
    --privileged -ti --rm \
    -v ./config:/config \
    -v ./cache:/var/cache/jugendhackt-iso \
    -v ./sda.img:/dev/sda jugendhackt-iso:latest \
    /jugendhackt-iso.sh /dev/sda
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
