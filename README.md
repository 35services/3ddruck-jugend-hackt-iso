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
- put files such as a welcome text on the desktop
- optional SSH access with public keys only
- install Inkscape extensions from `.zip` archives, e.g. for the AxiDraw pen plotter

## Usage

### Prepare the configuration

```shell
## setup before first run

# copy config.sample to config in the same directory
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
 
nano config

# required for the 3D-Druck-AG configuration: copy secrets.sample to secrets
# and set SNAPMAKER_USERNAME, SNAPMAKER_PASSWORD, MAKERWORLD_USERNAME and MAKERWORLD_PASSWORD
cp secrets.sample secrets
nano secrets

```

### 3D-Druck-AG configuration

This branch adjusts `config.sample` for a 3D printing and plotting club ("3D-Druck AG"):

- **Added:**
  - [OpenSCAD](https://openscad.org/) and [FreeCAD](https://www.freecad.org/) from Debian
  - [PrusaSlicer](https://flathub.org/apps/com.prusa3d.PrusaSlicer) and [UltiMaker Cura](https://flathub.org/apps/com.ultimaker.cura) from Flathub
  - [Snapmaker Orca](https://github.com/Snapmaker/OrcaSlicer) v2.4.0 as a Flatpak bundle, since it isn't on Flathub
  - the [AxiDraw extension](https://wiki.evilmadscientist.com/Axidraw_Software_Installation) v3.9.5 for Inkscape
- **Removed:** IntelliJ IDEA, Collabora Office, LibreSprite, Godot, Fritzing, Android SDK, Android Studio, Zulip and TIC-80
- **Kept:** LibreOffice as the only office suite. It's no longer listed in `ADDITIONAL_PACKAGES`, but Debian's `gnome` meta package installs it anyway.

The live user is `druck` with the Debian Live default password `live`, set in `data/live.conf`. The user is only created on a stick's first boot: a stick whose persistence partition already has a user keeps that user.

Slic3r is not included: it is neither on Flathub nor in Debian sid. Its maintained successor is PrusaSlicer.

### Flatpak bundles

Apps that are not on Flathub can be installed from `.flatpak` bundle files by listing their download URLs in `ADDITIONAL_FLATPAK_BUNDLES`. Bundles must be built for x86_64. Their runtimes are installed from Flathub. Bundles don't update automatically, so bump the URL to update an app.

### Inkscape extensions

`INKSCAPE_EXTENSION_ZIPS` lists `.zip` archives to install into the live user's Inkscape extensions directory (`/etc/skel/.config/inkscape/extensions`). If an archive contains a single top-level folder, its contents are copied rather than the folder itself. This requires `inkscape` in `ADDITIONAL_PACKAGES`.

The files reach the user via `/etc/skel` (see [Desktop files](#desktop-files)), on the first login. A stick whose user has already logged in once won't receive them.

To connect to an AxiDraw over USB, the user needs to be in the `dialout` group, which `data/live.conf` already sets.

### Desktop files

All files in `data/desktop` are copied to the live user's desktop on the first login, by `data/copy-desktop-files.sh` via an autostart entry. It uses the language-specific desktop folder (e.g. `Desktop` or `Schreibtisch`), runs once per user so deleted files are not restored, and also works for users that already exist on a stick. It also copies the files from `/etc/skel` that are missing in the home folder, without overwriting any: `data/persistence.conf` keeps `/home/druck` on the persistence partition, so the home folder already exists when live-config creates the user, and live-config then skips `/etc/skel`. To show the files on the GNOME desktop, the build installs and enables the Desktop Icons NG extension. The 3D-Druck-AG configuration ships a German welcome text, `LIESMICH.txt`, and `axidraw.txt` with links to the AxiDraw documentation, third-party software and the AG's projects.

The welcome text refers to `snapmaker-konto.txt` and `makerworld-konto.txt`, which the build writes to the desktop with the logins for the AG's Snapmaker and MakerWorld accounts. Set `SNAPMAKER_USERNAME`, `SNAPMAKER_PASSWORD`, `MAKERWORLD_USERNAME` and `MAKERWORLD_PASSWORD` in `secrets` (a copy of `secrets.sample`) during setup: the build refuses to start without them. Since `secrets` is ignored by git, the login never ends up in the repository. It is stored in plain text on every stick, though. The Ansible playbook `ansible/desktop-files.yml` reads the same file. Changing only a login doesn't change the cache identifier, so delete the cached `.erofs` file to rebuild with a new login.

### App menu entries

The `.desktop` files in `data/applications` are copied to `/etc/skel/.local/share/applications`, where they replace the app menu entries of installed apps with the same name. `ansible/snapmaker-orca.yml` installs the same entry on a machine.

Currently this fixes Snapmaker Orca: its startup script forces `LC_ALL=C.UTF-8`, which makes its web view fail with "invalid language tag", so no online content loads. The replacement entry starts the app directly with `LC_ALL=en_US.UTF-8`. Like the Inkscape extensions, it reaches the user via `/etc/skel` on the first login.

### SSH access

Public keys listed in `SSH_AUTHORIZED_KEYS` can log in as the live user via SSH, e.g. `ssh druck@<ip-address>`. If the list is set, the build installs `openssh-server` and `data/sshd_config.conf` disables password and root logins via SSH. The keys are stored in `/etc/ssh/jugendhackt_authorized_keys` inside the image, so they also work on sticks whose persistence partition already contains the user. Each stick generates its own SSH host keys on first boot.

### Ansible

The playbooks in `ansible/` set up an installed Ubuntu or Debian machine, such as the AG's laptop, which is listed in `ansible/inventory.ini`. Run them from the `ansible/` folder, e.g. `ansible-playbook -i inventory.ini auto-login.yml --ask-become-pass`. Playbooks that need sudo ask for the user's password with `--ask-become-pass`. Ubuntu 25.10 and newer use sudo-rs, whose password prompt Ansible doesn't recognize, so it times out with "Timeout waiting for privilege escalation prompt". The inventory therefore sets `ansible_become_exe=sudo.ws`, the classic sudo that Ubuntu still installs.

- `build-dependencies.yml` installs Docker and the tools to build the image.
- `snapmaker-orca.yml` installs Snapmaker Orca and its fixed app menu entry (see [App menu entries](#app-menu-entries)).
- `desktop-files.yml` copies `data/desktop` to the user's desktop and writes the account logins from `secrets` (see [Desktop files](#desktop-files)). It doesn't need sudo.
- `gnome-dash.yml` saves the GNOME Dash (the favorite apps in the dock) of a machine to `ansible/files/favorite-apps.json` with `--tags save`, and applies it otherwise. It also puts a Snapmaker Orca launcher with the locale fix on the desktop and marks it as trusted, so Desktop Icons NG starts it. It changes the running desktop session, so the user must be logged in. The `sticks` group in the inventory is for booted sticks.
- `oh-my-zsh.yml` installs zsh and [Oh My Zsh](https://ohmyz.sh/) for the user and makes zsh the login shell. Instead of piping the official installer into `sh`, it clones Oh My Zsh and copies its `.zshrc` template, which is what the installer does. An existing `~/.zshrc` is kept.
- `auto-login.yml` lets the kids use the machine without a password: GDM logs the user in automatically, and the lock screen is off, also after suspend. sudo still asks for the password. It takes effect after the next restart.

`auto-login.yml` doesn't change power settings. With Ubuntu's defaults, the screen turns off after 5 minutes without use. On battery, the machine suspends after 15 minutes, and it also suspends when the lid is closed. On the AG's laptop, automatic suspend while plugged in is turned off in the settings, so it stays awake unless the lid is closed.

Without a password at login, Ubuntu's login keyring stays locked, so apps that store passwords, such as a browser, may ask for it. To prevent this, give the keyring an empty password once on the machine: in *Passwörter und Verschlüsselung* (Seahorse), right-click *Anmeldung*, choose *Passwort ändern* and leave the new password empty. Saved passwords are then stored unencrypted.

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
    -v "$(pwd)/secrets":"/secrets" \
    -v "$(pwd)/cache":"/var/cache/jugendhackt-iso" \
    registry.git.alpaka.space/aic/jugendhackt-iso:main \
    /jugendhackt-iso.sh build

# run the script with access to all the resources it needs and flash the image onto the USB drive
docker run --privileged -ti --rm \
    -v "$(pwd)/config":"/config" \
    -v "$(pwd)/secrets":"/secrets" \
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

