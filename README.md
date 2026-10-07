# jugendhackt-iso.sh

**Please note:** This project lives on https://git.alpaka.space/aic/jugendhackt-iso.
The mirror on https://gitlab.com/Jugendhackt/jugendhackt-iso is no longer maintained.

Bootstraps a persistent Debian-based live system on a USB stick.

## Features

- make Debian persistent on your USB
- apply a sharable configuration via a single config file
- create a customized Debian environment with frequently used APT and Flatpak packages
- cache customized system in order to speed up further USB creation
- supports Austrian German *<3 Jh Linz, love you*
- supports Swiss keyboard layout *<3 Jh Zurich, love you*
- install Flatpak bundles (`.flatpak` files) for apps not available on Flathub
- install Inkscape extensions from `.zip` archives, e.g. for the AxiDraw pen plotter

## Usage

### Prepare the configuration

```shell
## setup before first run

# copy config.sample to config in the same directory
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
 
nano config

```

### 3D-Druck-AG configuration

This branch adjusts `config.sample` for a 3D printing and plotting club ("3D-Druck AG"):

- **Added:**
  - [OpenSCAD](https://openscad.org/) and [FreeCAD](https://www.freecad.org/) from Debian
  - [PrusaSlicer](https://flathub.org/apps/com.prusa3d.PrusaSlicer) from Flathub
  - [Snapmaker Orca](https://github.com/Snapmaker/OrcaSlicer) v2.4.0 as a Flatpak bundle, since it isn't on Flathub
  - the [AxiDraw extension](https://wiki.evilmadscientist.com/Axidraw_Software_Installation) v3.9.5 for Inkscape
- **Removed:** LibreOffice, Godot, Fritzing, Android SDK, Android Studio, Zulip and TIC-80

The live user is `druck` with the Debian Live default password `live`, set in `data/live.conf`. The user is only created on a stick's first boot: a stick whose persistence partition already has a user keeps that user.

Slic3r is not included: it is neither on Flathub nor in Debian sid. Its maintained successor is PrusaSlicer.

### Flatpak bundles

Apps that are not on Flathub can be installed from `.flatpak` bundle files by listing their download URLs in `ADDITIONAL_FLATPAK_BUNDLES`. Bundles must be built for x86_64. Their runtimes are installed from Flathub. Bundles don't update automatically, so bump the URL to update an app.

### Inkscape extensions

`INKSCAPE_EXTENSION_ZIPS` lists `.zip` archives to install into the live user's Inkscape extensions directory (`/etc/skel/.config/inkscape/extensions`). If an archive contains a single top-level folder, its contents are copied rather than the folder itself. This requires `inkscape` in `ADDITIONAL_PACKAGES`.

Since the files are copied from `/etc/skel`, they only reach users created from the image. A stick whose persistence partition already contains the user won't receive them.

To connect to an AxiDraw over USB, the user needs to be in the `dialout` group, which `data/live.conf` already sets.

### Build using Docker

**Note:** The prebuilt image `registry.git.alpaka.space/aic/jugendhackt-iso:main` may not contain `curl` and `unzip` yet, which are needed for Flatpak bundles and Inkscape extensions. In that case, build the image locally with `docker build -t jugendhackt-iso .` and use `jugendhackt-iso` instead of the registry image in the commands below.

```shell
# install Docker in case you didn't do so before
# 
# e.g. on Ubuntu, execute : 
# $ sudo apt install docker.io
# $ sudo usermod -aG docker $USER
# $ newgrp docker

# ensure we can use bubblewrap (https://deb.li/bubblewrap)
sudo sysctl kernel.unprivileged_userns_clone=1

# once create a build cache for the current configuration
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh build

# run the script with access to all the resources it needs and flash the image onto the USB drive
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    -v "/dev":"/dev" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh image
```

### Flash the image to a USB drive

1. Download [Etcher](https://etcher.balena.io/)
2. Select the disk image path displayed in the output of the last command
3. Select the USB drive
4. Flash

### Standalone using system libraries

The script will check all dependencies and tell you how to install them. Downloading Flatpak bundles and Inkscape extensions requires `curl` and `unzip`.

```shell
# ensure we can use bubblewrap (https://deb.li/bubblewrap)
sudo sysctl kernel.unprivileged_userns_clone=1

# create build cache
sudo ./jugendhackt-iso.sh build

# create an image file to flash on USB drives
sudo ./jugendhackt-iso.sh image

# test the built image using QEMU (requires at least 12 GiB of RAM on your machine)
./jugendhackt-iso.sh qemu uefi # or bios
```

The environment variable `CACHE_PATH` controls where the resulting erofs image will be stored and read from. If unset, it will default to `/var/cache/jugendhackt-iso`.

### Build on AArch64 / Apple Silicon / Raspberry Pi

As of now, it's not possible to build on AArch64 since we need to execute native binaries for amd64 in order to build the sticks for amd64. My past attempts using qemu-binfmt were not successful.

## Functionality

The jugendhackt-iso script passes two general stages :

1. boostrap a base system according to a config file or use a cached version
2. creata disk image to simply flash on a USB drive, make it bootable, persistent and Secure Boot compatible

The first stage uses `deboostrap` in order to boostrap a Debian base system. Next, APT packages, flatpaks, Flatpak bundles and Inkscape extensions are installed according to the configuration and locale settings are applied.

Once the bootstrap is done, the compressed base system is stored in `/var/cache/jugendhackt-iso` to reuse it for the next use of the same configuration.

In case the script finds a cache present for the used config file, the entire step is skipped.

The second stage populates the available system to a disk image file. It is therefore completely formatted with four partitions being created : a BIOS grub partition for legacy boot, an EFI system partition for UEFI boot, a root partition containing the bootloader, the kernel and the compressed system as well as an empty partition used for persistance.

Once the image is created, you can use a tool like [Etcher](https://etcher.balena.io/) or the `dd` command to flash it onto your USB drives.

## Legal

This project was written for [Jugend hackt](https://jugendhackt.org), an Austrian, German and Swiss project getting youth closer to ethical technology. This project is not officially affiliated with Jugend hackt.

License: [EUPL-1.2](LICENSE)

Author: The one with the braid <info@braid.business>

