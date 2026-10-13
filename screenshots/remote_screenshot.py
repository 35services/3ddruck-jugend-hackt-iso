#!/usr/bin/env python3
# Runs on a stick (piped in by screenshots.py over SSH: ssh <host> python3 -) and
# prints one line of JSON: the screenshot as base64 PNG, the desktop's version.txt
# and the error, if any.
#
# GNOME on Wayland only takes screenshots for callers on its allowlist, which it
# checks by the D-Bus names they own. So this script takes the name of GNOME's own
# screenshot app, org.gnome.Screenshot, and then asks GNOME Shell for a screenshot.
# Without PyGObject (python3-gi), it falls back to gnome-screenshot.

import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

SCREENSHOT_NAME = "org.gnome.Screenshot"


def session_env():
    env = dict(os.environ)
    # an SSH login has no session bus of its own, the desktop's is at the user's runtime dir
    runtime_dir = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    env["XDG_RUNTIME_DIR"] = runtime_dir
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime_dir}/bus")
    return env


def shot_with_gnome_shell(path, env):
    os.environ.update(env)
    from gi.repository import Gio, GLib

    bus = Gio.DBusConnection.new_for_address_sync(
        env["DBUS_SESSION_BUS_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)
    # 4 = DBUS_NAME_FLAG_DO_NOT_QUEUE, the reply 1 means we own the name now
    (reply,) = bus.call_sync(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        GLib.Variant("(su)", (SCREENSHOT_NAME, 4)), GLib.VariantType("(u)"),
        Gio.DBusCallFlags.NONE, -1, None).unpack()
    if reply != 1:
        raise RuntimeError(f"{SCREENSHOT_NAME} is taken by another app (gnome-screenshot open?)")

    # GNOME Shell learns about the new owner asynchronously, so retry a denied call
    for attempt in range(5):
        try:
            success, _ = bus.call_sync(
                "org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot", "org.gnome.Shell.Screenshot",
                "Screenshot", GLib.Variant("(bbs)", (False, False, path)), GLib.VariantType("(bs)"),
                Gio.DBusCallFlags.NONE, 20000, None).unpack()
            break
        except GLib.Error as error:
            if "AccessDenied" not in error.message or attempt == 4:
                raise
            time.sleep(0.3)
    if not success:
        raise RuntimeError("GNOME Shell couldn't take the screenshot")


def shot_with_gnome_screenshot(path, env):
    if not shutil.which("gnome-screenshot"):
        raise RuntimeError("neither python3-gi nor gnome-screenshot is installed")
    subprocess.run(["gnome-screenshot", "-f", path], env=env, check=True, timeout=30,
                   capture_output=True)


def desktop_dir(env):
    try:
        out = subprocess.run(["xdg-user-dir", "DESKTOP"], env=env, capture_output=True,
                             text=True, timeout=5).stdout.strip()
        if out and Path(out) != Path.home():
            return Path(out)
    except (OSError, subprocess.SubprocessError):
        pass
    for name in ("Schreibtisch", "Desktop"):
        if (Path.home() / name).is_dir():
            return Path.home() / name
    return None


def main():
    env = session_env()
    result = {"png": None, "version": None, "error": None}

    desktop = desktop_dir(env)
    if desktop and (desktop / "version.txt").is_file():
        result["version"] = (desktop / "version.txt").read_text(errors="replace").strip()

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "screen.png")
        errors = []
        for shot in (shot_with_gnome_shell, shot_with_gnome_screenshot):
            try:
                shot(path, env)
                if os.path.getsize(path) > 0:
                    break
            except Exception as error:  # report every way that failed, not just the last
                errors.append(f"{shot.__name__}: {error}")
        if os.path.exists(path) and os.path.getsize(path) > 0:
            result["png"] = base64.b64encode(Path(path).read_bytes()).decode()
        else:
            result["error"] = "; ".join(errors)

    print(json.dumps(result))


if __name__ == "__main__":
    main()
