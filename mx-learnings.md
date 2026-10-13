# MX Linux: learnings

What we learned while trying MX Linux 25.3 Xfce (Debian 13 "trixie", antiX live
system, sysvinit) on the AG's 12" MacBook (MacBook8,1), as a possible base for
future images. The experiment's overview is in `README.md`, "Experiment: MX
Linux"; this file collects the details and pitfalls.

## The MacBook's disk

| Partition | Size | Content |
|---|---|---|
| `nvme0n1p1` | 300 MB | EFI (macOS's, also used by Debian's GRUB) |
| `nvme0n1p2` | 326 GB | macOS (APFS) |
| `nvme0n1p3` | 93 GB | Debian, the stick's system installed (`druck`, `3d-ag-macbook-one`), holds `/isos` |
| `nvme0n1p4` | 19.5 GB | MX Linux (`mx`, `3d-ag-macbook-one-mx`) |
| free | 27 GB | right after `nvme0n1p4`, can be added to it |

Debian's GRUB starts everything: "MX Linux Live (ISO)" and "MX Linux", both
added by `ansible/mx-linux-iso.yml`.

## Live system (booted from the ISO on the disk)

- `ansible/mx-linux-iso.yml` copies the ISO to `/isos` on Debian and adds a
  GRUB entry that loop-mounts it (`fromiso=`, `buuid=`). No USB stick needed,
  which matters since the MacBook has only one USB port.
- The MacBook's keyboard needs `modprobe.blacklist=dw_dmac_pci`, like Debian.
  After sleep it stops working again, so don't let the live system sleep.
- Live user `demo`, password `demo`, root password `root`, hostname `mx1`
  (`mx1.local`).
- It has no SSH server and a firewall (ufw) that is switched on:
  `sudo apt install -y openssh-server`, `sudo service ssh start`,
  `sudo ufw allow 22/tcp`, then `ssh-copy-id demo@mx1.local`.
- It makes new SSH host keys on every boot. Use a separate known_hosts file,
  e.g. `ssh -o UserKnownHostsFile=~/.ssh/known_hosts_mx demo@mx1.local`.
- Everything is lost on restart. Its RAM overlay (~6 GB) held Orca, Inkscape,
  OpenSCAD and FreeCAD, but not PrusaSlicer and Cura as well.
- `toram` (the "to RAM" GRUB entry) copies the system into RAM first (~2 GB
  more RAM), so the disk the ISO is on is no longer in use.

## Installing MX next to Debian

- **The MX Installer hides the disk the live system was booted from.** Booted
  from the ISO on the internal disk, its partition list is empty, while
  GParted shows everything. The live system records the boot partition in
  `/live/config/initrd.out` (`BOOT_DEV`).
  - Fix without restarting: close the installer and GParted, then
    `sudo -E minstall --brave` in a terminal. `--brave` turns off this check.
    The desktop launcher (`minstall-launcher`) doesn't accept options.
  - Alternatively boot with `toram`, or from a USB stick.
  - With `--brave`, the partition the live system runs from (`nvme0n1p3`,
    Debian) is shown too. Don't touch it.
- Partition page: the free partition → `/`, **Format: ext4**. The default
  "Beste…" (keep existing) fails with "Die Daten in /home können nicht
  erhalten werden…" on an empty partition.
- No `/boot/efi` assigned → warning "möglicherweise ein nicht-bootbares
  System". Answer **Ja** and untick installing GRUB: Debian's GRUB stays in
  charge, and the Mac's boot setup isn't touched.
- Swap: the default is a swap file as large as RAM plus hibernation (~11 GB on
  a 19.5 GB partition). Use ~2 GB, no hibernation (it would need a `resume=`
  option, and waking breaks the keyboard anyway), plus Zram.
- Network page: hostname `3d-ag-macbook-one-mx`, leave the domain, untick
  Samba. Don't use `local` as the domain (clashes with mDNS `.local`).
- User page, like the sticks: `druck` / `live`, no root account, automatic
  login on, "Änderungen der Live-Arbeitsoberfläche speichern" off.
- Debian's GRUB gets the entry in `/etc/grub.d/43_mx-linux` (from
  `mx-linux-iso.yml`, found by the label `mx`). It uses MX's `/vmlinuz` and
  `/initrd.img` links, which MX's kernel updates keep current. Debian has no
  `/etc/default/grub`, so os-prober is off and MX isn't found by itself.
- From the live system, Debian's partition is mounted writable at
  `/run/initramfs/iso-dev`, so Debian's GRUB can be updated in a chroot
  (bind-mount `/dev`, `/proc`, `/sys`, then `chroot … update-grub`).

## The installed MX

- The firewall is on and blocks SSH: `sudo ufw allow 22/tcp`. The live
  system's ufw rule doesn't carry over; run it again after the first boot.
- The installer copied `~/.ssh/authorized_keys` of `demo` to `druck` (same UID
  1000), so key login worked right away.
- Ansible: `[mx]` in `ansible/inventory.ini`, host `macbook-one-mx-linux`.
- `sudo` asks for the password over SSH each time (no shared timestamp without
  a terminal); use `sudo -S` or Ansible's `ansible_become_password`.
- Renaming: `/etc/hostname`, `/etc/hosts` (127.0.1.1), `hostname <new>`,
  `service avahi-daemon restart`. The mDNS name changes immediately; accept the
  SSH host key once more for the new name.

## sysvinit instead of systemd

- MX starts with sysvinit (`ansible_service_mgr: sysvinit`). Packages that
  only ship a systemd unit don't start.
- Tailscale: its package has only `tailscaled.service`. `tailscale.yml` now
  installs `ansible/files/tailscaled.init` on sysvinit, using
  `/etc/default/tailscaled` (PORT, FLAGS) like the systemd service.
- MX's Xfce session has no systemd user services: the Geteilter Ordner's
  Syncthing ran from an Xfce autostart entry instead.

## Ansible playbooks on MX

| Playbook | On MX | Note |
|---|---|---|
| `snapmaker-orca.yml` | yes (`build:mx`) | see below |
| `desktop-files.yml`, `default-apps.yml`, `oh-my-zsh.yml` | yes | work unchanged |
| `tailscale.yml` | yes | with the sysvinit start script |
| `auto-login.yml` | no | GDM only; MX uses LightDM, the installer set autologin |
| `gnome-dash.yml` | no | Xfce has no GNOME Dash |
| `orca-scale.yml` | no | Orca's size is right on the Retina screen |

- Xfce's panel: Whisker menu (app menu, favorites in xfconf
  `/plugins/plugin-<n>/favorites`) and docklike (dock, pinned apps in
  `~/.config/xfce4/panel/docklike-<n>.rc`, read when the panel starts).
  `xfconf-query` needs the session's `DBUS_SESSION_BUS_ADDRESS`, e.g. from
  `/proc/<xfce4-panel pid>/environ`.

## Snapmaker Orca: Flatpak or AppImage

| | Flatpak (sticks, Ubuntu laptops) | AppImage | AppImage, unpacked |
|---|---|---|---|
| Download | ~0.7 GB (runtime 433 MB + bundle 106 MB + extensions) | 126 MB | 126 MB |
| On disk | ~1.6–1.8 GB (GNOME runtime 1.13 GB) | 126 MB | 356 MB (measured) |
| Extra packages | `flatpak`, GNOME runtime from Flathub | none, MX has WebKitGTK 4.1, GTK 3, GStreamer, FUSE 2 | none, no FUSE needed |
| System libraries | from the runtime | from MX | from MX |
| Locale | forces `LC_ALL=C.UTF-8`, breaks the web view → launcher in `data/applications` | `AppRun` forces `LC_ALL=C` | same, or skip `AppRun` |

- Sizes: the GNOME runtime per Flathub's API (`installed_size`,
  `download_size`); the stick image is ~12–13 GB, leaving ~17–18 GB (32 GB
  stick) or ~49–50 GB (64 GB stick) for persistence. On the sticks the runtime
  is inside the image, not in persistence.
- Unpacking: `./Snapmaker_Orca.AppImage --appimage-extract` → `squashfs-root`.
  **`libexec/snapmaker-orca-env` has mode 754** inside the AppImage: unpacked
  as root, other users can't run it ("cannot execute: Permission denied").
  Fix with `chmod -R a+rX`.
- `AppRun` sets `LC_ALL=C` and calls
  `libexec/snapmaker-orca-env bin/snapmaker-orca`. Starting the wrapper
  directly allows another locale (`LC_ALL=en_US.UTF-8`, available on MX).
- Test (2026-10-13): through `AppRun` it starts and shows the splash screen.
  Whether the main window and the web view work with `LC_ALL=C`, and with
  `en_US.UTF-8`, is still to be tested. On MX there are two launchers for it:
  "Snapmaker Orca" and "Snapmaker Orca (English)".

## Working with Claude Code

- A git worktree lacks the ignored files (`secrets`, `config`, `cache`):
  `desktop-files.yml` failed without `secrets`. Link them from the main
  checkout (see `CLAUDE.md`).
- `pkill -f <pattern>` over SSH also matches the SSH command itself if the
  pattern appears in it, and kills the session. Match the process name instead.
- Screenshots of the MX desktop over SSH: `DISPLAY=:0 import -window root
  /tmp/shot.png`, then `scp`.
