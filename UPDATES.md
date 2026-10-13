# Keeping devices up to date

**Status: plan, not built yet.**

Machines boot in a usable state from the image: a stick, or a stick's system
installed onto a disk (see "Install a stick's system onto a disk" in
`README.md`). From then on, every machine updates itself: when this branch has
a new commit, it runs the Ansible playbooks the repository lists for it. Nobody
has to reach the machines, and changes are made in one place, in git.

Everything here is public: the repository only contains device and group names
and the Debian Live default password `live`, which is public anyway. The
devices belong to public schools, and no names of students are involved.

## Overview

```
 GitHub: 35services/3ddruck-jugend-hackt-iso, branch 3d-druck-ag
   ansible/devices.yml   which device is in which group, which playbooks it gets
   ansible/*.yml         the playbooks
        │
        │  git fetch, hourly and after login (nothing is pushed to the devices)
        ▼
 every device: ansible-update.timer → /usr/local/bin/ansible-update.sh
   1. fetch the branch
   2. new commit since the last successful run? Otherwise stop.
   3. look itself up in ansible/devices.yml, by its device name
   4. run its playbooks against itself (ansible-playbook, connection local)
   5. write down the commit it applied
```

There is no server: GitHub is the only thing the devices need, besides internet.

## The inventory: `ansible/devices.yml`

A YAML inventory. Groups are schools, AGs or anything else that shares a setup.
A group lists its playbooks in `playbooks`; a device can override the list.

```yaml
all:
  vars:
    ansible_connection: local     # every device runs the playbooks on itself
    ansible_user: druck
    ansible_become_password: live # the Debian Live default, public anyway
    desktop_logins: false         # the image puts the account logins on the desktop
  children:
    druck_ag:                     # the 3D-Druck-AG
      vars:
        playbooks: [auto-login.yml, desktop-files.yml, gnome-dash.yml, default-apps.yml, oh-my-zsh.yml]
      hosts:
        3d-ag-macbook-one:        # Debian installed next to macOS
        3d-ag-001:
        3d-ag-002:
    schule_beispiel:              # another school, e.g. with its own Syncthing hub
      vars:
        playbooks: [auto-login.yml, desktop-files.yml]
      hosts:
        beispiel-001:
          playbooks: []           # paused: this device gets nothing for now
```

- **Group names** use underscores, since Ansible warns about `-` in group names.
- **Removing a device** from the file stops its updates. It keeps its state.
- **Multiple Syncthing groups:** the Geteilter Ordner
  ([3ddruck-geteilter-ordner](https://github.com/35services/3ddruck-geteilter-ordner))
  can take its hub and folder from group variables, e.g. `geteilter_ordner_hub`,
  so each school syncs only among its own devices. That's a change in that
  project. A device would also need its playbooks from there, see
  [Open questions](#open-questions).
- `ansible/inventory.ini` stays for running playbooks from a Mac over SSH,
  e.g. for a device that isn't online often.

### Which device am I?

A device's name is in `/etc/jugendhackt-iso/device` (one line). Without the
file, the device uses its hostname.

All sticks of one image have the same hostname (the ID of the Docker container
that built it), so **sticks need the file**. Set it once on each stick, with the
name from `devices.yml`; the persistence partition keeps it:

```sh
echo 3d-ag-001 | sudo tee /etc/jugendhackt-iso/device
```

A device that isn't in `devices.yml` does nothing and logs its name, so it can
be added.

## The runner on each device

Part of the image (`data/`, installed by `jugendhackt-iso.sh`):

- `/usr/local/bin/ansible-update.sh`: the steps from the [overview](#overview).
  It clones the branch to `~/.cache/jugendhackt-iso/repo` (shallow), reads the
  device's `playbooks` with `ansible-inventory --host`, and runs
  `ansible-playbook -i devices.yml --limit <device> <playbooks>`.
- `ansible-update.service` and `ansible-update.timer`: **systemd user units**
  for `druck`, in `/etc/systemd/user`, enabled for every user. The timer runs 2
  minutes after login and then hourly. It runs as the user, not as root,
  because most playbooks change the user's settings, and `gnome-dash.yml` needs
  the running desktop session. Playbooks that need root use sudo with `live`.
- The image installs `ansible-core` and `git`. The playbooks only use
  `ansible.builtin` modules, so the full `ansible` package isn't needed.

**Only on a new commit:** the runner remembers the last commit it applied
successfully (`~/.cache/jugendhackt-iso/applied-commit`) and does nothing
until the branch changes. So the kids' own changes, like a rearranged dock,
stay until the AG changes something in the repository. A failed run, e.g.
without internet halfway through, isn't remembered and is retried at the next
start of the timer. Any commit to the branch, even one to the README, makes
every device run its playbooks once. They are idempotent, so that's harmless.

A stick's first run after flashing applies all its playbooks once, since
nothing is remembered yet.

Logs: `journalctl --user -u ansible-update` on the device.

## How do we know a device is up to date?

A device is up to date when the commit it last applied is the branch's current
commit. Three ways to see it, from simplest to most central:

1. **On the device:** the runner writes the state to `version.txt` on the
   desktop, below the image's version:
   `Ansible: Stand 4b3e51f vom 13.10.2026 16:20, erfolgreich`. Anyone at the
   machine can read it, and it shows the last failure too.
2. **From the Mac, on demand:** a small playbook, `ansible/update-status.yml`,
   reads `applied-commit` and the last run's result from every device in
   `inventory.ini` and compares them with the branch. It prints a table of
   device, applied commit, behind or current, last run. It only reaches
   devices that are online.
3. **Reported by the devices** (optional): after each run, the runner sends
   one line (`device, commit, result, time`) somewhere central. Possible
   destinations, without our own server:
   - a status file per device in the Geteilter Ordner, which every device
     already syncs (e.g. `.status/3d-ag-001.txt`; `.txt` files are synced).
     The hub's Mac then has the overview of all devices of its group.
   - a public [ntfy](https://ntfy.sh) topic, which the AG can subscribe to on
     a phone.

   Devices never get credentials to write to GitHub.

Option 1 and 2 need nothing new; 3 is worth it once there are several schools.

## Open questions

- **Playbooks from the Geteilter Ordner:** the runner fetches only this
  repository. Either the client playbook moves here, or the runner also fetches
  that repository. Registering a new device at the hub needs the hub's API
  key, which shouldn't be on the devices: the hub (or its Mac) could accept
  devices that `devices.yml` lists instead.
- **Branch:** devices follow `3d-druck-ag`, so every push reaches all devices
  within an hour. A separate branch for the devices (e.g. `devices`), which is
  moved forward after testing, would allow trying changes first.
- **Installed machines:** the MacBook gets the runner by hand until a machine
  installed from a new image has it anyway.
