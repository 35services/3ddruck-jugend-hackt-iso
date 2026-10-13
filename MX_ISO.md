# An image based on MX Linux

**Status: plan, not built yet.**

The sticks run Debian sid with GNOME, built by `jugendhackt-iso.sh`. MX Linux
(Debian stable with Xfce) promises to run better on the AG's older machines,
and it held up on the 12" MacBook (README.md, "Experiment: MX Linux";
`mx-learnings.md`). This plan builds a second image from MX, side by side with
the Debian one, until it has proven itself on the AG's machines.

Decided (2026-10-14):

- **Remaster MX's ISO in the existing Docker build**, not `mx-snapshot` of a
  machine set up by hand: the image stays reproducible from this repository.
- **systemd** is the default init, not MX's sysvinit. MX's ISO has both. With
  systemd, Tailscale, Syncthing's user service, the persistence growing and
  the planned `ansible-update.timer` (`UPDATES.md`) work like on the Debian
  sticks, without the sysvinit start scripts.
- **Side by side:** its own name `jugendhackt-3d-druck-mx-iso`, the same
  version numbers and `CHANGELOG.md` as the Debian image.

## What MX's ISO contains

Checked on `MX-25.3_Xfce_x64.iso` (September 20, 2026), on the MacBook:

| Path | Content |
|---|---|
| `antiX/linuxfs` | the system, squashfs with zstd, 2.7 GB (7.2 GB unpacked, `linuxfs.info`) |
| `antiX/vmlinuz`, `antiX/initrd.gz` | kernel and antiX's live initrd |
| `antiX/*.md5` | checksums, checked with the boot option `checkmd5` |
| `boot/grub/grub.cfg`, `boot/grub/config/*.cfg` | GRUB menu: entries "(sysvinit)" and "(systemd)" (`init=/lib/systemd/systemd`), language, keyboard, time zone, persistence |
| `boot/isolinux`, `boot/syslinux` | BIOS boot |
| `EFI/BOOT` | shim (`bootx64.efi`), `grubx64.efi`, MokManager: Secure Boot |

- The live user is `demo` (UID 1000, password `demo`), already in
  `linuxfs`'s `/etc/passwd`, set up at boot by `/etc/init.d/live-setup`
  (and `live-setup.service` for systemd).
- Persistence is antiX's own: ext4 *files* in `antiX/` on the stick, not a
  partition. Of its modes, **`p_static_root`** ("root and home together on
  the persistence device") is the one like the Debian sticks: everything is
  written to the stick right away, in the file `antiX/rootfs`. `persist_all`
  keeps `/` in RAM and saves it at shutdown, which loses data when a stick is
  pulled.
- MX's tools for this: `live-usb-maker` (makes a stick from an ISO),
  `persist-makefs` (creates `rootfs`), `mx-snapshot` (an ISO of the running
  system).

## Compared with the Debian image

| Step | Debian image (`jugendhackt-iso.sh`) | MX image (`mx-iso.sh`) |
|---|---|---|
| Base system | `debootstrap sid`, then apt installs GNOME, live-boot, kernel, GRUB | download the pinned MX ISO, check its sha256, `unsquashfs antiX/linuxfs`: Xfce, kernel and live system are there |
| Debian | sid, changes daily | 13 "trixie" (stable) plus MX's repositories |
| Desktop | GNOME, `gnome-shell-extension-desktop-icons-ng`, `90-jugendhackt-iso.gschema.override` | Xfce: the desktop shows `~/Desktop` itself, favorites in the Whisker menu and the dock via xfconf (`mx-learnings.md`) |
| Languages | `task-<language>` and `task-<language>-desktop` packages (`TASK_LANGUAGES`) | MX's locales and its language menu at boot; German as the default in `grub.cfg` (`lang=de_DE`), language packs only where needed |
| apt packages | `ADDITIONAL_PACKAGES` from `config` | the same, plus `gstreamer1.0-x` (Orca's camera view, `mx-learnings.md`) |
| Flatpaks | Flathub apps and bundles, installed from the build environment (`flatpak_env`) | the same code; MX has Flatpak |
| Snapmaker Orca | Flatpak bundle, launcher in `data/applications` | the same Flatpak: the AppImage depends on system packages that are easy to miss |
| Inkscape extensions, desktop files, logins, `version.txt` | `/etc/skel`, `copy-desktop-files.sh` as XDG autostart | the same; Xfce runs XDG autostart entries |
| SSH | `SSH_AUTHORIZED_KEYS`, `data/sshd_config.conf` | the same, plus `ufw allow 22/tcp` (MX's firewall is on) |
| The MacBook's keyboard | not in the image | `dw_dmac_pci` blacklisted, the sleep hook in `/usr/lib/systemd/system-sleep` |
| Packing | `mkfs.erofs` → `.live/filesystem.squashfs` | `mksquashfs -comp zstd` → `antiX/linuxfs`, new `.md5` files and `linuxfs.info` (antiX's initrd expects squashfs) |
| Boot | own `data/grub.cfg`, `grub-install` for BIOS and UEFI (shim) | MX's GRUB, isolinux and shim, only `grub.cfg` changed: systemd entry first, German, `p_static_root` |
| Stick | 4 partitions: BIOS, ESP, `BOOT` (ext4), persistence (ext4) | 2 partitions like `live-usb-maker`: ESP and one ext4 with `antiX/` and `antiX/rootfs` |
| Filling the stick | `grow-persistence.service` grows the persistence partition on the first boot | `antiX/rootfs` has a fixed size: grow the partition and the file on the first boot, or create it at the stick's size when flashing (to find out) |
| Test | QEMU, expect logs in on the serial console as `druck` | QEMU UEFI and BIOS; MX logs in to Xfce by itself, so the test checks differently, e.g. over SSH |
| Pipeline | `Dockerfile`, `build-and-flash.sh`, `cache/<name>-v<version>.img` | the same, `mx-iso.sh` reuses `config`, `secrets` and `data/` |

## Open questions

Answered by the spike (step 1):

1. **The live user.** Can `live-setup` make `druck` (password `live`) instead
   of `demo`, e.g. by renaming the account in `linuxfs`, or does antiX expect
   `demo`? The playbooks, the inventory and `UPDATES.md` use `druck`.
2. **Persistence growth.** Does `p_static_root` boot without asking with a
   ready-made `antiX/rootfs`? Can the file grow on the first boot (partition,
   then file, then `resize2fs` while mounted), or does the image have to be
   created at the stick's size?
3. **Checksums.** Does the initrd check `linuxfs.md5` only with `checkmd5`, or
   always?
4. **systemd.** Does MX's live system (`live-setup.service`, autologin with
   LightDM, persistence) work the same booted with systemd?
5. **Secure Boot.** Does MX's shim start the remastered system unchanged? The
   kernel isn't changed, so it should.

## Steps

0. Merge the MX branch's remaining commits (`mx-learnings.md`, Snapmaker
   Orca's AppImage, `tailscaled` on sysvinit) together with this plan.
1. **Spike** on the Lenovo (`druck-lenovo.local`, x86_64, ~30 GB free): unpack
   `linuxfs`, rename the user, add a file, pack it again, boot it in QEMU,
   then put it on a stick with `p_static_root`. Answers the open questions.
2. **`mx-iso.sh`** with the stages of `jugendhackt-iso.sh` (`build`, `image`,
   `qemu`, `test`), the MX ISO's URL and sha256 in `config.sample`, and
   `squashfs-tools` and `xorriso` in the `Dockerfile`.
3. **Port** what the Debian image contains, row by row in the table above.
4. **The stick**: partitions, `antiX/rootfs`, growing it.
5. **Test** in QEMU, then on the MacBook and the AG's older machines, side by
   side with a Debian stick: start time, Snapmaker Orca, slicing
   (`mx-learnings.md`, "Performance").
6. **Release**: `.iso-name` holds one name, so `mx-iso.sh` gets its own
   (`jugendhackt-3d-druck-mx-iso`); update `CLAUDE.md` and record the image in
   `CHANGELOG.md` like any other.
