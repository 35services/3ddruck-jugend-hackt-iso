# Screenshots of the AG's machines

`screenshots.py` runs on the host computer (the Mac or any machine in the tailnet).
It finds the AG's machines in the tailnet, takes a screenshot of each one's desktop
over SSH and puts them on one web page, together with the `version.txt` from each
desktop, so you can see at a glance what is on every screen and which image it runs.

```sh
# once: screenshots and page in screenshots/out/index.html
./screenshots/screenshots.py

# new screenshots every 30 seconds, page on http://localhost:8000/ (reloads itself)
./screenshots/screenshots.py --interval 30 --serve 8000
```

It only needs Python 3 and the `tailscale` CLI on the host, on a Mac it uses the one
in the Tailscale app. The page and pictures go to `screenshots/out/`, which git ignores.

## Which machines

All machines whose name in the tailnet matches `--match`, by default `^3d-ag-`, the
names `tailscale.yml` gives them (`tailscale_hostname`). Offline machines get a grey
card. The script connects by their Tailscale address as `--user` (default `druck`).

## What the machines need

- Tailscale, logged in (`ansible/tailscale.yml`)
- SSH with the host's key: on sticks from `SSH_AUTHORIZED_KEYS` in `config`, on
  installed machines in `~/.ssh/authorized_keys`. The script uses `BatchMode`, so it
  never asks for a password. New host keys are accepted the first time; when a stick
  is reflashed, remove its old key with `ssh-keygen -R <tailscale address>`.
- A logged-in GNOME session (automatic on sticks, `ansible/auto-login.yml` elsewhere)
- `python3-gi`, or else `gnome-screenshot`

## How the screenshot is taken

`remote_screenshot.py` is piped to `python3 -` on the machine, so nothing is installed
there. GNOME on Wayland only takes screenshots for its own apps, which it recognizes by
the D-Bus names they own. The script connects to the desktop session's bus
(`/run/user/<uid>/bus`), takes the name of GNOME's screenshot app,
`org.gnome.Screenshot`, and calls GNOME Shell's `org.gnome.Shell.Screenshot`. It takes
the picture silently, without flash or sound. If `gnome-screenshot` is open on the
machine, it owns that name, and the script falls back to running `gnome-screenshot`.
