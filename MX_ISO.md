# An image based on MX Linux

**Status: plan, not built yet.**

The sticks run Debian sid with GNOME, built by `jugendhackt-iso.sh`. MX Linux
(Debian stable with Xfce) promises to run better on the AG's older machines,
and it held up on the 12" MacBook (README.md, "Experiment: MX Linux";
`mx-learnings.md`). This plan builds a second image from MX, side by side with
the Debian one, until it has proven itself on the AG's machines.

## The approach: a master system and a snapshot

MX and antiX make their images the way their users customize them: set up a
system, then turn it into a live ISO. `mx-snapshot` does that for an installed
system, antiX's `live-remaster` for a running live stick
([video](https://www.youtube.com/watch?v=LpI_a4xPKdM)), and `live-usb-maker`
puts the ISO on sticks, with persistence. This plan uses MX's tools for that:

```
 MX ISO (pinned version, sha256)
        │ installed once
        ▼
 the master: MX in a virtual machine on the Lenovo (KVM)
        │ set up only by the Ansible playbooks in ansible/
        │ (the same ones the installed machines get, UPDATES.md)
        ▼
 mx-snapshot --cli, without the master's own state
        │
        ▼
 cache/jugendhackt-3d-druck-mx-iso-v<version>.iso
        │ live-usb-maker, with persistence
        ▼
 the sticks
```

- **All of the master's state comes from Ansible**, nothing is set up by
  hand. The playbooks are the only description of the setup, for the sticks,
  the installed machines and the planned self-updates (`UPDATES.md`). What
  `jugendhackt-iso.sh` installs today moves into playbooks.
- **Newer MX versions get the same customizations:** install the new MX
  release, run the same playbooks, take a snapshot. The customizations don't
  depend on one ISO's internals, unlike a remaster of its `linuxfs`.
- **Reproducible from git:** the MX version and the playbooks are in git; a
  new master is an MX installation plus one `ansible-playbook` run.
- **What is tested is what goes on the sticks.** The master is a normal MX
  system: set it up, try it, snapshot it.
- **The master is a virtual machine on the Lenovo**, not a real computer: it
  has none of a computer's own state (Tailscale, Syncthing, Wi-Fi), the
  Lenovo is fast (8 cores, 30 GB RAM, 190 GB free), and it can be reset to
  the bare installation (snapshot of the VM disk) before each build.
- **A first try uses the MacBook's MX** (`3d-ag-macbook-one-mx`), which is
  set up with the playbooks (step 1). It isn't a clean master: during the
  experiment some steps ran by hand (MX installer, `ufw`, Orca's unpacking,
  the Geteilter Ordner, Xfce favorites; `mx-learnings.md`), and it is a real
  computer with its own Tailscale and Syncthing identity.

Decided (2026-10-14):

- **systemd** is the default init, not MX's sysvinit. MX's ISO has both. With
  systemd, Tailscale, Syncthing's user service and the planned
  `ansible-update.timer` (`UPDATES.md`) work like on the Debian sticks,
  without the sysvinit start scripts.
- **Side by side:** its own name `jugendhackt-3d-druck-mx-iso`, the same
  version numbers and `CHANGELOG.md` as the Debian image.

### Considered: taking MX's ISO apart in Docker

The first version of this plan (2026-10-14) unpacked MX's `antiX/linuxfs` in
the Docker build, changed it in a chroot like `jugendhackt-iso.sh` and packed
it again. Also reproducible from git, but it rebuilds by hand what MX's tools
do (squashfs, md5 files, boot menu, live user), its shell code would exist
next to the playbooks for the same setup, and the result is only seen after
the build. It remains the fallback if `mx-snapshot` can't be driven by a
script.

## What must not get into the image

A snapshot copies the master's state. `mx-snapshot`'s exclude list
(`/usr/share/excludes/mx-snapshot-exclude.list`) leaves out `machine-id`,
logs, the apt cache, histories and `var/lib/NetworkManager`, but not
everything that makes a computer unique. Checked on the MacBook's MX:

| State | Excluded by default | On every stick, it would |
|---|---|---|
| `/var/lib/tailscale` | no | make all sticks the same Tailscale node |
| `~/.local/state/geteilter-ordner` (Syncthing's keys) | no | make all sticks the same device for the hub |
| `/etc/NetworkManager/system-connections` | only with `-x Networks` | carry the Wi-Fi passwords |
| `/etc/ssh/ssh_host_*` | no | be the same, unless the live system makes new ones at boot (MX's did in the experiment) |
| `/etc/hostname`, `/etc/hosts` | no | be the master's name |

So the build uses its own exclude list (`snapshot_excludes` in
`/etc/mx-snapshot.conf`): MX's plus these. On the master VM, Tailscale and the
Geteilter Ordner aren't set up at all; the list protects against a snapshot
of a real machine such as the MacBook.

## What MX's ISO contains

Checked on `MX-25.3_Xfce_x64.iso` (September 20, 2026), on the MacBook. A
snapshot has the same layout.

| Path | Content |
|---|---|
| `antiX/linuxfs` | the system, squashfs with zstd, 2.7 GB (7.2 GB unpacked, `linuxfs.info`) |
| `antiX/vmlinuz`, `antiX/initrd.gz` | kernel and antiX's live initrd |
| `antiX/*.md5` | checksums, checked with the boot option `checkmd5` |
| `boot/grub/grub.cfg`, `boot/grub/config/*.cfg` | GRUB menu: entries "(sysvinit)" and "(systemd)" (`init=/lib/systemd/systemd`), language, keyboard, time zone, persistence |
| `boot/isolinux`, `boot/syslinux` | BIOS boot |
| `EFI/BOOT` | shim (`bootx64.efi`), `grubx64.efi`, MokManager: Secure Boot |

- MX's own live user is `demo` (UID 1000), set up at boot by
  `/etc/init.d/live-setup` (`live-setup.service` for systemd). A snapshot
  *without* `--reset` ("personal") keeps the master's accounts, i.e. `druck`
  (password `live`) with its home folder; with `--reset` it goes back to
  `demo` and `/etc/skel`.
- Persistence is antiX's own: ext4 *files* in `antiX/` on the stick, not a
  partition. Of its modes, **`p_static_root`** ("root and home together on
  the persistence device") is the one like the Debian sticks: everything is
  written to the stick right away, in the file `antiX/rootfs`. `persist_all`
  keeps `/` in RAM and saves it at shutdown, which loses data when a stick is
  pulled.
- `mx-snapshot` 26.10.1 (on the MacBook): `--cli`, `--file`, `--directory`,
  `--workdir`, `--compression zstd`, `--exclude Networks`, `--reset`;
  settings in `/etc/mx-snapshot.conf` (default compression lz4, exclude list,
  `edit_boot_menu`).

## Compared with the Debian image

| Step | Debian image (`jugendhackt-iso.sh`) | MX image (master and snapshot) |
|---|---|---|
| Base system | `debootstrap sid`, then apt installs GNOME, live-boot, kernel, GRUB | MX installed from the pinned ISO into the master VM: Xfce, kernel, live tools are there |
| Debian | sid, changes daily | 13 "trixie" (stable) plus MX's repositories |
| Setting it up | shell code in `build_erofs`, in a chroot | Ansible playbooks against the running master |
| Desktop | GNOME, `gnome-shell-extension-desktop-icons-ng`, `90-jugendhackt-iso.gschema.override` | Xfce: the desktop shows `~/Desktop` itself, favorites in the Whisker menu and the dock via xfconf (`mx-learnings.md`) |
| Languages | `task-<language>` and `task-<language>-desktop` packages (`TASK_LANGUAGES`) | MX's locales and its language menu at boot; German as the default |
| apt packages | `ADDITIONAL_PACKAGES` from `config` | a playbook with the same list, plus `gstreamer1.0-x` (Orca's camera view) |
| Flatpaks | Flathub apps and bundles, installed from the build environment (`flatpak_env`) | a playbook, installed in the running master; MX has Flatpak |
| Snapmaker Orca | Flatpak bundle, launcher in `data/applications` | `snapmaker-orca.yml` with the Flatpak: the AppImage depends on system packages that are easy to miss |
| Inkscape extensions, desktop files, logins, `version.txt` | `/etc/skel`, `copy-desktop-files.sh` as XDG autostart | `desktop-files.yml` and a playbook for the AxiDraw extension, into `druck`'s home (kept by the snapshot) |
| SSH | `SSH_AUTHORIZED_KEYS`, `data/sshd_config.conf` | a playbook, plus `ufw allow 22/tcp` (MX's firewall is on) |
| The MacBook's keyboard | not in the image | `dw_dmac_pci` blacklisted, the sleep hook (only acts on a MacBook8,1) |
| Making the live system | `mkfs.erofs`, own `data/grub.cfg`, `grub-install` for BIOS and UEFI (shim) | `mx-snapshot --cli`: squashfs, md5 files, MX's GRUB, isolinux and shim |
| Stick | 4 partitions: BIOS, ESP, `BOOT` (ext4), persistence (ext4), written with `dd` | `live-usb-maker`: ESP and one ext4 with `antiX/` and `antiX/rootfs` |
| Filling the stick | `grow-persistence.service` grows the persistence partition on the first boot | `antiX/rootfs` has a fixed size, created by `live-usb-maker` or `persist-makefs` (to find out) |
| Test | QEMU, expect logs in on the serial console as `druck` | try it on the master before the snapshot; boot the ISO in QEMU (UEFI, BIOS) |
| Build machine | Docker on the Lenovo, `build-and-flash.sh` | a VM on the Lenovo (KVM), a new script driving it over SSH |

## Open questions

Answered by the first try (step 1) and the master (step 2):

1. **The live user.** Does a personal snapshot boot straight into `druck`'s
   desktop (autologin, home folder from the snapshot), and does
   `live-setup` leave the account alone?
2. **Persistence on the sticks.** Does `p_static_root` boot without asking?
   Can `live-usb-maker` create `antiX/rootfs` at the stick's size, or does it
   have to grow on the first boot?
3. **systemd.** Can the snapshot's boot menu start with systemd by default
   (`edit_boot_menu`, or the master booting with systemd), and do MX's live
   scripts work the same?
4. **Unattended.** Does `mx-snapshot --cli` run without questions, so a
   script can drive it? Can `live-usb-maker` run on the Lenovo's Ubuntu, or
   only in the VM with the stick passed through?
5. **Secure Boot.** Does the snapshot keep MX's shim, so it starts with
   Secure Boot?

## Steps

0. Merge the MX branch's remaining commits (`mx-learnings.md`, Snapmaker
   Orca's AppImage, `tailscaled` on sysvinit) together with this plan.
1. **First try on the MacBook's MX:** `mx-snapshot --cli` in personal mode,
   with the exclude list above and zstd, to `/home/snapshot` (~13 GB of system,
   a 5–6 GB ISO, 32 GB free). Copy the ISO to the Lenovo, boot it in QEMU.
   Answers questions 1, 3 and 5.
2. **The master VM on the Lenovo:** install MX from the pinned ISO (disk
   ~60 GB), user `druck` / `live`, systemd; keep the bare installation as a
   VM disk snapshot.
3. **Playbooks for what the image contains**, row by row in the table above:
   apt packages, Flatpaks, Inkscape extensions, SSH keys, logins and
   `version.txt` from `secrets`. A group `[mx_master]` in the inventory.
4. **A script** that resets the VM, starts it, runs the playbooks, runs
   `mx-snapshot` and copies the ISO to `cache/`, named after `.iso-name` (its
   own for MX, `jugendhackt-3d-druck-mx-iso`) and the version.
5. **The sticks** with `live-usb-maker` and persistence (question 2).
6. **Test** on the MacBook and the AG's older machines, side by side with a
   Debian stick: start time, Snapmaker Orca, slicing (`mx-learnings.md`,
   "Performance").
7. **Release:** update `CLAUDE.md` and record the image in `CHANGELOG.md`
   like any other.
