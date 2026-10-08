# ISO build log: building the image on the AG's laptop over SSH

A log of building the 3D-Druck-AG image on the laptop `druck-TravelMate-P653-M`
(Ubuntu 26.04, x86_64), driven from a Mac over SSH. Long-running steps run in
`screen` sessions, so they keep going when the SSH connection drops or the Mac
goes to sleep.

Started on 2026-10-08.

## Overview

| Where | What |
|---|---|
| Mac | the git checkout, `secrets`, Ansible |
| Laptop | Docker, the build itself |
| `workspace` stick on the laptop (32 GB, ext4) | the repo copy, the build cache and temporary files |

The build happens on the stick because it unpacks the whole system into
`/var/tmp` first. With all the apps and Flatpaks that needs more space than the
laptop's system disk has free (11 GB).

## 1. Prepare the laptop (once)

On the Mac, in `ansible/`, install Docker and the build tools:

```sh
ansible-playbook -i inventory.ini build-dependencies.yml --ask-become-pass
```

Check that it worked, over SSH:

```sh
ssh druck-TravelMate-P653-M.local
docker info --format '{{.ServerVersion}}'           # Docker runs without sudo
id -nG                                              # contains docker and kvm
sysctl kernel.apparmor_restrict_unprivileged_userns # 0, needed by bubblewrap
```

If `id -nG` doesn't list `docker` yet, log out and back in.

## 2. Prepare the workspace stick

The stick is formatted as ext4 with the label `workspace`. GNOME mounts it
automatically at `/run/media/druck/workspace`, but with `nodev,nosuid`.
`nodev` breaks the build: debootstrap creates device files like `/dev/null`
in the new system and uses them. Check the mount options and remount it:

```sh
findmnt -no OPTIONS /run/media/druck/workspace   # shows nosuid,nodev
sudo mount -o remount,dev,suid /run/media/druck/workspace
findmnt -no OPTIONS /run/media/druck/workspace   # now rw,relatime,...
```

The remount only lasts until the stick is unplugged or the laptop restarts.
Repeat it before every build.

Check the free space:

```sh
df -h /run/media/druck/workspace
```

## 3. Copy the repo to the stick

On the Mac, from the repo root. `rsync` copies only what changed, so run it
again after every change. `.git` and the cache stay on the Mac:

```sh
rsync -a --exclude .git --exclude cache --exclude .DS_Store --exclude pages \
  ./ druck-TravelMate-P653-M.local:/run/media/druck/workspace/jugendhackt-iso/
```

This also copies `secrets` with the account logins. They end up on every stick
anyway, but keep the file private on the laptop:

```sh
ssh druck-TravelMate-P653-M.local
cd /run/media/druck/workspace/jugendhackt-iso
cp --update=none config.sample config   # this branch's config is the AG config
chmod 600 secrets
mkdir -p ../cache ../tmp                # build cache and temporary files
```

## 4. Build the Docker image

The registry image `registry.git.alpaka.space/aic/jugendhackt-iso:main` doesn't
contain this branch's changes, since the `Dockerfile` copies `data/` and
`jugendhackt-iso.sh` into the image. So build it locally, on the laptop:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
docker build -t jugendhackt-iso .
docker images jugendhackt-iso
```

Rebuild it after every change to `data/` or `jugendhackt-iso.sh`.

## 5. Build the system in a screen session

`screen` keeps a terminal running on the laptop independently of SSH. The
basics:

| Command | What it does |
|---|---|
| `screen -S iso` | start a new session called `iso` |
| `Ctrl-a` then `d` | detach: leave it running and go back to the normal shell |
| `screen -ls` | list the running sessions |
| `screen -r iso` | reattach to the session |
| `exit` inside the session | end it |

Start the build in a session called `iso`, logging everything to a file:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
screen -S iso -L -Logfile ../build.log
```

Inside the session:

```sh
docker run --privileged -t --rm \
  -v "$PWD/config":/config \
  -v "$PWD/secrets":/secrets \
  -v "$PWD/../cache":/var/cache/jugendhackt-iso \
  -v "$PWD/../tmp":/var/tmp \
  jugendhackt-iso /jugendhackt-iso.sh build
```

- `--privileged` lets the container mount things and create loop devices.
- `-v "$PWD/../tmp":/var/tmp` puts the unpacked system on the stick instead of
  the system disk.

Then detach with `Ctrl-a` `d`. You can log out of SSH now.

You can also start it detached in one go, without attaching first. The
`echo` afterwards writes the exit code to the log, and `exec bash` keeps the
session open, so you can still read the end of the output with `screen -r iso`:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
screen -dmS iso -L -Logfile ../build.log bash -c '
  docker run --privileged -t --rm \
    -v "$PWD/config":/config \
    -v "$PWD/secrets":/secrets \
    -v "$PWD/../cache":/var/cache/jugendhackt-iso \
    -v "$PWD/../tmp":/var/tmp \
    jugendhackt-iso /jugendhackt-iso.sh build
  echo "=== build exited with code $? at $(date +%T)"
  exec bash'
```

To wait until it's done, e.g. from another SSH session:

```sh
until grep -q "=== build exited" /run/media/druck/workspace/build.log; do sleep 60; done
```

To check on it later, without attaching:

```sh
tail -f /run/media/druck/workspace/build.log   # Ctrl-c to stop watching
df -h /run/media/druck/workspace               # space used so far
```

When it's done, the cache contains `<checksum>.erofs`, the compressed system.
The checksum is that of `config`, so a changed `config` means a new build.

## Watching disk space

Docker keeps its images and containers under `/var/lib/docker`, on the
system disk, not on the stick. The local image alone takes about 2 GB, so
keep an eye on both disks:

```sh
df -h / /run/media/druck/workspace
docker system df          # how much Docker uses
```

To log the free space every minute in the background, start a detached
screen session (`-d -m`), named `space`, which runs a loop:

```sh
screen -dmS space bash -c 'while true; do
  echo "$(date +%T) system: $(df -h --output=avail / | tail -1 | tr -d " ") free, workspace: $(df -h --output=avail /run/media/druck/workspace | tail -1 | tr -d " ") free" \
    >> /run/media/druck/workspace/disk-space.log
  sleep 60
done'
```

Read it with `tail /run/media/druck/workspace/disk-space.log`, and stop it with
`screen -S space -X quit`.

If the system disk gets full, `docker image prune` removes unused images and
`docker builder prune` removes Docker's build cache.

## What the build does

Docker is only the workbench: the container brings the tools (debootstrap,
mkfs.erofs, grub, ...), so the laptop's Ubuntu doesn't need them. The actual
work happens in a plain folder on the stick.

1. **`build`:** debootstrap unpacks a minimal Debian into a folder in
   `/var/tmp` (= `tmp/` on the stick). With `chroot`, which starts programs so
   that they see that folder as `/`, the script runs `apt install` inside it,
   installs the Flatpaks and copies the configuration. `mkfs.erofs` then
   compresses the folder into one read-only file, `cache/<checksum>.erofs`.
2. **`image`:** creates `cache/<checksum>.img` with four partitions: GRUB for
   BIOS and UEFI, `BOOT` with the `.erofs` file, kernel and initrd, and the
   persistence partition `Jugend-hackt-USB`.
3. **On a stick:** live-boot mounts the `.erofs` file as `/` and lays the
   persistence partition over it, so every change the kids make lands there.

## Changing files between the stages

The stages use the copy of `data/` and `jugendhackt-iso.sh` inside the Docker
image, not the files on the stick. After changing one of them, sync and
rebuild the Docker image. That's quick, since Docker reuses the package layer:

```sh
# on the Mac
rsync -a data/ druck-TravelMate-P653-M.local:/run/media/druck/workspace/jugendhackt-iso/data/
# on the laptop
cd /run/media/druck/workspace/jugendhackt-iso && docker build -t jugendhackt-iso .
```

A running container keeps the image it started with, so this is safe during a
build.

Which stage a file belongs to decides whether a change needs a new build:

- **only `image`:** `data/persistence.conf` and `data/grub.cfg` are copied
  onto the stick's partitions. Rebuild the Docker image and run `image` again.
- **`build`:** everything that ends up in the system, e.g. packages in
  `config`, `data/desktop`, `data/applications`. The `.erofs` file only
  depends on the checksum of `config`, so delete it to force a new build.

## 6. Create the USB image

After the build, in a screen session again. `-v /dev:/dev` lets the
container use loop devices to partition the image file:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
screen -dmS image -L -Logfile ../image.log bash -c '
  docker run --privileged -t --rm \
    -v "$PWD/config":/config \
    -v "$PWD/secrets":/secrets \
    -v "$PWD/../cache":/var/cache/jugendhackt-iso \
    -v "$PWD/../tmp":/var/tmp \
    -v /dev:/dev \
    jugendhackt-iso /jugendhackt-iso.sh image
  echo "=== image exited with code $? at $(date +%T)"
  exec bash'
```

The image ends up next to the `.erofs` file, as `cache/<checksum>.img`, with its
checksum in `cache/<checksum>.sum`. Flash it with Etcher or `dd` (see
"Flash the image to a USB drive" in the README).

## Space needed

The first build on the 32 GB stick ran out of space: the unpacked system alone
took 25 GB before the Flatpaks were done. Roughly, the stick needs:

| What | Size |
|---|---|
| unpacked system in `tmp/` (deleted after the `.erofs` is written) | 22–25 GB |
| `cache/<checksum>.erofs` | about half of that |
| `cache/<checksum>.img` (stage 6) | size of the `.erofs` + 1 GB |

So use a disk with 64 GB or more.

## Plan for the second build (on the 64 GB SSD)

Prepared on 2026-10-08:

- `config.sample` without IntelliJ IDEA, Collabora Office and LibreSprite.
- `data/persistence.conf` keeps `/home/druck` instead of the old user's home.
- Flatpak runs directly in the container (`flatpak_env` in
  `jugendhackt-iso.sh`), which fixes the `bwrap` errors, see the log below.
  The Docker image is rebuilt with it.

Steps:

1. Unplug the old 32 GB stick, so there aren't two disks labeled `workspace`.
2. Format the SSD as ext4 with the label `workspace`, in Disks with the quick
   option. It's then mounted at `/run/media/druck/workspace` again, so all
   commands in this file stay the same.
3. Remount it (step 2): `sudo mount -o remount,dev,suid /run/media/druck/workspace`
4. Copy the repo (step 3), and copy the new config:
   `cp config.sample config`
5. The Docker image is already built. If `data/` or the script changed since,
   rebuild it (step 4).
6. Start the build (step 5) and the `space` session.
7. Create the image (step 6) and flash a stick.

## Log

- **2026-10-08 22:13:** copied the repo to the stick (step 3).
- **2026-10-08 22:14:** started the Docker image build (step 4).
- **2026-10-08:** remounted the stick without `nodev,nosuid` (step 2).
- **2026-10-08 22:21:** system disk at 8.7 GB free (was 11 GB before the
  Docker image build), workspace at 27 GB. Started the `space` screen session.
- **2026-10-08 22:23:** Docker image `jugendhackt-iso:latest` done (1.97 GB,
  about 9 minutes). Started the build in the `iso` screen session (step 5),
  debootstrap is downloading the base system.
- **2026-10-08 22:38:** 15 minutes in, installing packages. The stick has
  22 GB free (5 GB used), the system disk is unchanged at 8.7 GB. The build
  installs LibreOffice: the `gnome` meta package pulls it in, although the
  branch removed it from `ADDITIONAL_PACKAGES`. Leaving it out would need
  LibreOffice in `PACKAGE_REMOVAL`.
- **2026-10-08 23:03:** `data/persistence.conf` still kept `/home/alpaka`,
  the old user's home, separately. Changed it to `/home/druck source=Druck`,
  synced it and rebuilt the Docker image (only the `COPY` steps ran again).
  It only affects the `image` stage, so the running build doesn't need to start
  over.
- **2026-10-08:** the build installs IntelliJ IDEA, which came from the
  original Jugend-hackt list in `ADDITIONAL_FLATPAKS`. Removed IntelliJ IDEA,
  Collabora Office and LibreSprite from `config.sample` on the Mac, for the
  next build. LibreOffice stays as the only office suite. The laptop's
  `config` is unchanged, so the running build continues as it is.
- **2026-10-08 23:25:** the stick is almost full: 1.8 GB free, losing about
  0.5 GB per minute while the Flatpaks install. The unpacked system takes 25 GB.
  It can't fit the `.erofs` file as well, so the build can't finish.
- **2026-10-08 23:30:** stopped the build with `docker stop` (254 MB left).
  The unpacked system stays in `tmp/` and belongs to root. Free it with
  `sudo rm -rf /run/media/druck/workspace/tmp/*`, or just reformat the stick.
- **2026-10-08:** looked into `bwrap: Creating new namespace failed: Operation
  not permitted`, printed three times after every Flatpak, and the failed
  install of `org.freedesktop.Platform.openh264`. The script ran Flatpak inside
  a bwrap sandbox (`bwrap_env`). Flatpak starts bwrap itself for its
  post-install steps, and in a throwaway container a bwrap inside a bwrap
  can't create any namespace, even as root. Flatpak run directly in the
  container, with `FLATPAK_SYSTEM_DIR` pointing to the new system's
  `/var/lib/flatpak`, installs openh264 completely. Changed the script to
  that (`flatpak_env`), added `flatpak` to the `Dockerfile` and to
  `build-dependencies.yml`, and rebuilt the Docker image.
