#!/usr/bin/env python3
# Takes a screenshot of every AG machine in the tailnet and shows them on one web page.
# See README.md in this folder.

import argparse
import base64
import datetime
import html
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
REMOTE_SCRIPT = HERE / "remote_screenshot.py"
MAC_TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


def tailscale_binary(given):
    for candidate in (given, shutil.which("tailscale"), MAC_TAILSCALE):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    sys.exit("tailscale not found, pass its path with --tailscale")


def tailnet_machines(tailscale, match):
    status = json.loads(subprocess.run([tailscale, "status", "--json"], capture_output=True,
                                       text=True, check=True).stdout)
    machines = []
    for peer in (status.get("Peer") or {}).values():
        # the name in the tailnet (tailscale up --hostname), not the OS's hostname, which
        # is the same on every stick
        name = (peer.get("DNSName") or peer.get("HostName") or "").split(".")[0]
        if not re.search(match, name) or not peer.get("TailscaleIPs"):
            continue
        machines.append({"name": name, "address": peer["TailscaleIPs"][0],
                         "online": bool(peer.get("Online")), "os": peer.get("OS", "")})
    return sorted(machines, key=lambda m: m["name"])


def grab(machine, user, timeout):
    started = time.monotonic()
    result = {**machine, "png": None, "version": None, "error": None}
    if not machine["online"]:
        result["error"] = "offline"
        return result
    command = ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}",
               "-o", "StrictHostKeyChecking=accept-new", f"{user}@{machine['address']}", "python3", "-"]
    try:
        with REMOTE_SCRIPT.open("rb") as script:
            done = subprocess.run(command, stdin=script, capture_output=True, timeout=timeout + 40)
        if done.returncode != 0:
            raise RuntimeError(done.stderr.decode(errors="replace").strip() or f"ssh exited {done.returncode}")
        reply = json.loads(done.stdout.decode().strip().splitlines()[-1])
        result["version"] = reply.get("version")
        result["error"] = reply.get("error")
        if reply.get("png"):
            result["png"] = base64.b64decode(reply["png"])
    except Exception as error:
        result["error"] = str(error)
    result["seconds"] = round(time.monotonic() - started, 1)
    return result


def write_atomically(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(path)


def card(result, stamp):
    name = html.escape(result["name"])
    state = "ok" if result["png"] else ("offline" if result["error"] == "offline" else "error")
    if result["png"]:
        src = f"{name}.png?t={stamp}"
        picture = f'<a href="{src}" target="_blank"><img src="{src}" alt="Bildschirm von {name}" loading="lazy"></a>'
    else:
        picture = f'<div class="empty">{html.escape(result["error"] or "kein Bild")}</div>'
    details = f'<pre class="version">{html.escape(result["version"])}</pre>' if result["version"] else ""
    if result["png"] and result["error"]:
        details += f'<p class="note">{html.escape(result["error"])}</p>'
    return f"""<article class="card {state}">
  <header><span class="dot"></span><h2>{name}</h2><span class="addr">{html.escape(result["address"])}</span></header>
  {picture}
  {details}
</article>"""


def page(results, interval):
    now = datetime.datetime.now()
    stamp = int(now.timestamp())
    refresh = f'<meta http-equiv="refresh" content="{max(interval, 5)}">' if interval else ""
    ok = sum(1 for r in results if r["png"])
    cards = "\n".join(card(r, stamp) for r in results) or '<p class="none">Keine passenden Geräte im Tailnet.</p>'
    return f"""<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{refresh}
<title>3D-Druck-AG Bildschirme</title>
<style>
:root {{ --bg: #f6f6f4; --card: #fff; --text: #1d1d1b; --muted: #6b6b66; --line: #e2e2dc;
         --ok: #2f9e44; --off: #9a9a94; --err: #d9480f; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg: #161615; --card: #20201f; --text: #ececea; --muted: #9a9a94; --line: #34342f; }}
}}
* {{ box-sizing: border-box; }}
body {{ margin: 0; padding: 24px 16px; background: var(--bg); color: var(--text);
        font: 15px/1.4 system-ui, -apple-system, sans-serif; }}
h1 {{ font-size: 22px; margin: 0 0 4px; }}
.meta {{ color: var(--muted); margin: 0 0 20px; }}
.grid {{ display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 360px), 1fr)); }}
.card {{ background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }}
.card header {{ display: flex; align-items: center; gap: 8px; padding: 10px 12px; }}
.card h2 {{ font-size: 16px; margin: 0; }}
.addr {{ margin-left: auto; color: var(--muted); font: 13px ui-monospace, monospace; }}
.dot {{ width: 10px; height: 10px; border-radius: 50%; background: var(--ok); }}
.offline .dot {{ background: var(--off); }} .error .dot {{ background: var(--err); }}
img {{ display: block; width: 100%; height: auto; border-top: 1px solid var(--line); }}
.empty {{ aspect-ratio: 16 / 10; display: grid; place-items: center; padding: 16px; text-align: center;
          color: var(--muted); border-top: 1px solid var(--line); word-break: break-word; }}
.error .empty {{ color: var(--err); }}
.version {{ margin: 0; padding: 10px 12px; border-top: 1px solid var(--line); color: var(--muted);
            font: 12px/1.4 ui-monospace, monospace; white-space: pre-wrap; }}
.note {{ margin: 0; padding: 0 12px 10px; color: var(--err); font-size: 13px; }}
</style>
</head>
<body>
<h1>3D-Druck-AG Bildschirme</h1>
<p class="meta">{ok} von {len(results)} Geräten · Stand {now:%d.%m.%Y %H:%M:%S}{f" · alle {interval} s neu" if interval else ""}</p>
<main class="grid">
{cards}
</main>
</body>
</html>
"""


def round_of_screenshots(args, tailscale):
    machines = tailnet_machines(tailscale, args.match)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda m: grab(m, args.user, args.timeout), machines))
    for result in results:
        png = args.out / f"{result['name']}.png"
        if result["png"]:
            write_atomically(png, result["png"])
        elif png.exists():
            png.unlink()  # no old picture that looks current
        print(f"{result['name']:24} {result['address']:16} "
              f"{'ok' if result['png'] else result['error']}", flush=True)
    write_atomically(args.out / "index.html", page(results, args.interval).encode())


def serve(out, port):
    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=str(out), **kw)
    server = http.server.ThreadingHTTPServer(("", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Serving on http://localhost:{port}/", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Screenshots of the AG's machines in the tailnet")
    parser.add_argument("--match", default=r"^3d-ag-",
                        help="regex for the machines' tailnet names (default: %(default)s)")
    parser.add_argument("--user", default="druck", help="SSH user on the machines (default: %(default)s)")
    parser.add_argument("--out", type=Path, default=HERE / "out", help="folder for the page and pictures")
    parser.add_argument("--timeout", type=int, default=10, help="SSH connect timeout in seconds")
    parser.add_argument("--interval", type=int, default=0,
                        help="take new screenshots every N seconds, and reload the page as often")
    parser.add_argument("--serve", type=int, metavar="PORT", help="also serve the page on this port")
    parser.add_argument("--tailscale", help="path to the tailscale CLI")
    args = parser.parse_args()

    tailscale = tailscale_binary(args.tailscale)
    args.out.mkdir(parents=True, exist_ok=True)
    if args.serve:
        serve(args.out, args.serve)

    while True:
        round_of_screenshots(args, tailscale)
        print(f"Page: {args.out / 'index.html'}", flush=True)
        if args.interval:
            time.sleep(args.interval)
        elif args.serve:
            threading.Event().wait()  # keep serving
        else:
            break


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
