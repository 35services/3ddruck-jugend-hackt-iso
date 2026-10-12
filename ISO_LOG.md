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

When it's done, the cache contains `jugendhackt-iso-v<version>.erofs`, the
compressed system. The version is the latest one in `CHANGELOG.md` (see
`CLAUDE.md`), so a changed image needs a new version or a deleted `.erofs`.

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
   compresses the folder into one read-only file, `cache/jugendhackt-iso-v<version>.erofs`.
2. **`image`:** creates `cache/jugendhackt-iso-v<version>.img` with four partitions: GRUB for
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
  depends on the version in `CHANGELOG.md`, so delete it to force a new build.

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

The image ends up next to the `.erofs` file, as `cache/jugendhackt-iso-v<version>.img`, with its
checksum in `cache/jugendhackt-iso-v<version>.sum`. Flash it with Etcher or `dd` (see
"Flash the image to a USB drive" in the README).

## 7. Test the image in a virtual machine

The script boots the image in QEMU, a virtual computer, with `-snapshot`, so
the image file stays unchanged. The kernel also writes to a serial console
(`console=ttyS0` in `data/grub.cfg`), which QEMU shows in the terminal with
`-nographic`, so this works over SSH without a screen. It needs about 8 GB of
free RAM.

**Automated test:** boots the first menu entry, waits for the login, logs in as
`druck` with the password `live`, and shuts down again. It prints
`Test passed` or `Test test failed`:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
screen -dmS qemu -L -Logfile ../qemu.log bash -c '
  docker run --privileged -t --rm \
    -v "$PWD/config":/config \
    -v "$PWD/secrets":/secrets \
    -v "$PWD/../cache":/var/cache/jugendhackt-iso \
    jugendhackt-iso /jugendhackt-iso.sh test uefi
  echo "=== qemu exited with code $? at $(date +%T)"
  exec bash'
```

Use `test bios` instead of `test uefi` to test on an older, BIOS-only computer.
The log contains escape codes, so read it like this:

```sh
tr -d '\r' < ../qemu.log | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | less
```

**Interactive test session:** the same VM, but you operate it yourself in the
terminal: choose a GRUB entry with the arrow keys, log in, and try things out
on the command line. The graphical desktop isn't visible this way, only the
serial console:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
docker run --privileged -it --rm \
  -v "$PWD/config":/config \
  -v "$PWD/secrets":/secrets \
  -v "$PWD/../cache":/var/cache/jugendhackt-iso \
  jugendhackt-iso /jugendhackt-iso.sh qemu uefi headless
```

To quit QEMU, press `Ctrl-a` then `x`. Inside `screen`, `Ctrl-a` belongs to
screen, so press `Ctrl-a` `a` `x` there.

To see the desktop, run `./jugendhackt-iso.sh qemu uefi` without `headless`
directly on the computer's own screen (not in Docker, not over SSH). It opens
a QEMU window.

## Space needed

The first build on the 32 GB stick ran out of space: the unpacked system alone
took 25 GB before the Flatpaks were done. Roughly, the stick needs:

| What | Size |
|---|---|
| unpacked system in `tmp/` (deleted after the `.erofs` is written) | 22–25 GB |
| `cache/jugendhackt-iso-v<version>.erofs` | about half of that |
| `cache/jugendhackt-iso-v<version>.img` (stage 6) | size of the `.erofs` + 1 GB |

So use a disk with 64 GB or more.

## Building and flashing in one go

`build-and-flash.sh` runs steps 4 to 7 and flashes the image onto USB sticks,
without further interaction. Since erasing the sticks needs root, it runs with
`sudo`, so you only enter the password once at the start.

First find the sticks' permanent names. They contain the serial number, so a
stick can't be confused with another disk, even if `sdb` and `sdc` swap:

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,LABEL,MOUNTPOINTS
ls -l /dev/disk/by-id/ | grep -- '-0:0 '
```

Check what's on each stick before erasing it: two sticks of the same model look
the same, and one of them might be a system you still need.

Then, on the build machine:

```sh
cd /run/media/druck/workspace/jugendhackt-iso
screen -S buildflash -L -Logfile ../build-and-flash.log \
  sudo ./build-and-flash.sh /dev/disk/by-id/usb-…-0:0 /dev/disk/by-id/usb-…-0:0
```

Enter the password, check the `Stick:` lines it prints, and detach with
`Ctrl-a d`. The script:

1. checks that every stick is a whole USB disk and not the system disk
2. deletes the old image. The cache name only depends on `config`, so without
   this, a change in `data/` or the script wouldn't trigger a new build
3. rebuilds the Docker image, builds the system, creates the image
4. tests it in QEMU (step 7), and stops before touching the sticks if that fails
5. unmounts the sticks' partitions, erases them with `wipefs` and flashes them
   in parallel with `dd`
6. reads every stick back and compares it with the image: `OK: /dev/sdX
   matches the image`

To list its steps without the rest of the output:

```sh
tr -d '\r' < ../build-and-flash.log | grep -aE '^=== |Test passed|^OK:|^FAILED'
```

## Monitoring panes in tmux

On the Mac, a tmux window with Claude on the left and three panes on the right
that show the build machine. Use its LAN IP address with `-4`: it's on cable and
Wi-Fi at the same time, and over `.local` names or IPv6 the connection can
freeze. The loop reconnects when the connection drops:

```sh
H=192.168.178.121
tmux split-window -d -h -l 45% "while true; do ssh -4 -t -o ServerAliveInterval=15 $H 'tail -n 40 -F /run/media/druck/workspace/build-and-flash.log'; sleep 5; done"
tmux split-window -d -v -t work:0.1 -l 55% "while true; do ssh -4 -t -o ServerAliveInterval=15 $H .local/bin/iostat-build; sleep 5; done"
tmux split-window -d -v -t work:0.2 -l 30% "while true; do ssh -4 -t -o ServerAliveInterval=15 $H 'watch -n 10 df -h / /run/media/druck/workspace'; sleep 5; done"
```

`~/.local/bin/iostat-build` on the build machine runs
`iostat -y -h -c -d sda sdb sdc 5` with red numbers
(`S_COLORS_SGR="N=31;1:Z=31;22"`). It's a script because the quotes of that
setting don't survive tmux, the loop and SSH.

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
- **2026-10-09 09:36:** instead of the 64 GB SSD, booted the laptop's Ubuntu
  stick on another computer (`192.168.178.80`, 8 cores, 30 GB RAM) with a
  477 GB SATA SSD. Since it's the same stick, the SSH host key, Docker setup
  and the Docker image from last night are all there. The SSD (`/dev/sda1`,
  ext4, label `512_internal`) wasn't mounted, and `udisksctl mount` over SSH
  asks for a password it can't prompt for. So mount it by hand, directly
  without `nodev,nosuid`, at the usual path:
  `ssh -t druck@192.168.178.80 'sudo mkdir -p /run/media/druck/workspace && sudo mount -o dev,suid /dev/sda1 /run/media/druck/workspace'`
- **2026-10-09 09:38:** copied the repo, `cp config.sample config` (without
  IntelliJ IDEA, Collabora Office and LibreSprite), started the `space` and
  `iso` sessions as in steps 5 and "Watching disk space". 445 GB free.
- **2026-10-09 09:57:** build done after 19 minutes (over an hour on the
  laptop), exit code 0. `cache/9a012c26….erofs` is 12 GB. No `bwrap` errors
  this time, all 8 apps installed (7 from Flathub and the Snapmaker Orca
  bundle), and `org.freedesktop.Platform.openh264` installed completely, so
  the `flatpak_env` fix works.
- **2026-10-09 09:58:** started step 6 (image) in the `image` session. The
  `losetup` warning "file does not end on a 512-byte sector boundary" is
  harmless: the script's image size isn't a multiple of 512 bytes, so the last
  bytes are ignored.
- **2026-10-09 10:00:** image done, exit code 0, after 2 minutes:
  `cache/9a012c26….img`, 13 GB, sha256
  `a63c38e298a5a38f453a23408e37c719aff4f72c1f514501ba5dbc42bc0eccc2`.
  Flash it with `sudo dd if=<image> of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress`
  onto the whole stick (`sdX`, not `sdX1`), then check it with
  `sudo cmp -n $(stat -c %s <image>) <image> /dev/sdX`.
- **2026-10-09:** flashed the image onto the 32 GB stick with Disks
  ("Restore Disk Image…"). On a real computer it showed the GRUB menu but
  didn't start the system.
- **2026-10-09 10:54:** `test uefi` (step 7) passed: the image boots in QEMU,
  reaches the login, logs in and shuts down. So the image itself works; the
  problem is specific to the hardware. `error: can't find command
  'grub_platform'` in the GRUB output comes from `data/grub.cfg` and only
  affects the last two menu entries.
- **2026-10-09 11:10:** the stick from the first flash had no image on it at
  all, just an MBR with one empty partition, so the GRUB menu seen before was
  probably the computer's own. Flashed it again with `dd` to the stick's
  `/dev/disk/by-id/usb-…` name, which contains its serial number, so it can't
  hit another disk. Took 13½ minutes: the stick accepted the data in 7 minutes
  and needed another 6½ to write its cache (`conv=fsync` waits for that).
  Afterwards the stick showed the four partitions.
- **2026-10-09:** the Acer laptop said "Operating system not found" with the
  stick in one USB port and booted it from another. Older laptops often only
  boot from some ports, usually the USB 2 ones.
- **2026-10-09:** on the booted stick, Snapmaker Orca's fixed menu entry, the
  AxiDraw extension and even `.bashrc` were missing from `/home/druck`. The
  live-config log says "The home directory `/home/druck' already exists. Not
  touching this directory.": since `data/persistence.conf` keeps
  `/home/druck` on the persistence partition, the folder exists before the
  user is created, so `/etc/skel` isn't copied. Fixed on the stick with
  `cp -rn /etc/skel/. ~/`, and in `data/copy-desktop-files.sh` for the next
  image, which now copies missing `/etc/skel` files on the first login.
- **2026-10-09 12:32:** prepared the third build with `build-and-flash.sh`
  (see "Building and flashing in one go"), for the `/etc/skel` fix. The
  Lenovo had two sticks plugged in: a new one (serial `040185052f21…`, factory
  FAT32) and the old Ubuntu system stick (serial `040144699fdd…`), whose
  system now runs as a copy on the Lenovo. Both get erased.
- **2026-10-09 12:36:** started `build-and-flash.sh` in the `buildflash`
  screen session. Docker image from cache in 11 seconds, system built in 19
  minutes without `bwrap` errors, image created at 12:57 (13 GB, sha256
  `7e9c47ee1c366de1750effe0c239d1ea29b5393f9c0aa63b7031d548021f6398`),
  `Test passed` at 12:58, then both sticks flashing in parallel.
- **2026-10-09:** the tmux log pane closed when its SSH connection dropped.
  Rebuilt the monitoring panes with the LAN IP address, `-4`, and a reconnect
  loop (see "Monitoring panes in tmux").
- **2026-10-09 13:13:** both sticks flashed, but the comparison at the end
  reported `FAILED` for both: while `cmp` was reading them back, both sticks
  disconnected from USB and reconnected (`usb 2-5: USB disconnect` at
  13:13:32, `sdc` at 13:14), so the reads failed with `Input/output error`.
  Writing had already finished without errors. Booted from both sticks
  afterwards, and both work. If a comparison fails like this, check the
  kernel log for `USB disconnect` and repeat only the `cmp`, not the build.
