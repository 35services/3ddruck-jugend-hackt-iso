# CLAUDE.md

This branch builds the USB stick image of the 3D-Druck-AG with
`jugendhackt-iso.sh` (see `README.md`, and `ISO_LOG.md` for how it is built
and flashed in practice).

## Image versions and the changelog

- Every change to the image, i.e. to `jugendhackt-iso.sh`, `config.sample`,
  `data/`, `Dockerfile` or what the build puts on the sticks, is recorded in
  `CHANGELOG.md`, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):
  first under `## [Unreleased]`, in the sections Added, Changed, Deprecated,
  Removed, Fixed or Security.
- Versions are whole numbers (1, 2, 3, …), one for every image that is
  flashed onto sticks. To release one, rename `## [Unreleased]` to
  `## [<version>] - <YYYY-MM-DD>`, add a new empty `## [Unreleased]` above it,
  and update the links at the bottom: the previous version's link points to
  its commit.
- `.iso-version` contains the current version, the topmost released version
  in `CHANGELOG.md`, and nothing else. Update both together: the build takes
  the version from the changelog and stops if `.iso-version` differs.
- `.iso-name` contains the image's name, `jugendhackt-3d-druck-iso` (the 3D
  printing variant of the Jugend hackt ISO), and nothing else. Together with
  the version it names the build's files
  (`cache/jugendhackt-3d-druck-iso-v<version>.img`, `.erofs`, `.sum`), and
  both are shown in `version.txt` on the sticks' desktop.
