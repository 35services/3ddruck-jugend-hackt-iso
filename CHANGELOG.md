# Changelog

All notable changes to the 3D-Druck-AG's USB stick image are documented in
this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are whole numbers, one for every image that is flashed onto sticks.
The topmost released version is the version of the next build: together with
the name in `.iso-name` it names the image
(`jugendhackt-3d-druck-iso-v<version>.img`) and is shown in `version.txt` on
the desktop, and `.iso-version` must contain the same number.

## [Unreleased]

## [3] - 2026-10-12

### Added

- `version.txt` on the desktop with the image's name and version, when its
  build started and a link to this changelog. `LIESMICH.txt` points to it.
- This changelog and `.iso-version`, from which the build takes the version.
- `.iso-name` with the image's name, `jugendhackt-3d-druck-iso`, the 3D
  printing variant of the Jugend hackt ISO.

### Changed

- The image, the `.erofs` file and the checksum are named after `.iso-name`
  and the version, e.g. `jugendhackt-3d-druck-iso-v3.img`, instead of after
  the checksum of `config`.

## [2] - 2026-10-09

### Fixed

- Copy the files of `/etc/skel` that are missing in the home folder on the
  first login. The home folder is kept on the persistence partition, so it
  already exists when the user is created, and Snapmaker Orca's menu entry,
  the AxiDraw extension and `.bashrc` were missing.

## [1] - 2026-10-09

The first image of the 3D-Druck-AG, based on the Jugend hackt ISO.

### Added

- PrusaSlicer, UltiMaker Cura and Snapmaker Orca (as a Flatpak bundle) for
  slicing, OpenSCAD and FreeCAD for 3D models.
- Inkscape extensions, by default the AxiDraw plotter extension.
- Files on the desktop: a welcome text (`LIESMICH.txt`), AxiDraw links
  (`axidraw.txt`) and the logins of the AG's Snapmaker and MakerWorld
  accounts, taken from `secrets`.
- Optional SSH access with keys only, for maintenance.

### Changed

- The live user is called `druck`, and its home folder is kept on the
  persistence partition.
- Snapmaker Orca starts with an English locale.

### Removed

- Godot, Fritzing, the Android tools, Zulip, TIC-80, IntelliJ IDEA,
  Collabora Office and LibreSprite.

### Fixed

- Flatpaks are installed without a nested bwrap sandbox, so their
  post-install steps run and `org.freedesktop.Platform.openh264` installs
  completely.

[Unreleased]: https://github.com/35services/3ddruck-jugend-hackt-iso/tree/3d-druck-ag
[3]: https://github.com/35services/3ddruck-jugend-hackt-iso/tree/3d-druck-ag
[2]: https://github.com/35services/3ddruck-jugend-hackt-iso/tree/34f5d2b
[1]: https://github.com/35services/3ddruck-jugend-hackt-iso/tree/2a74bfb
