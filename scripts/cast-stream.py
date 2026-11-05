#!/usr/bin/env -S uv run --quiet
# /// script
# requires-python = ">=3.10"
# dependencies = ["pychromecast>=14.0.1"]
# ///
"""Cast a local media stream to a Google Cast device (Chromecast, Google TV, Nest Hub…).

Examples
--------
List what is on the network:
    uv run scripts/cast-stream.py --list

Cast the default stream (this machine's LAN IP on port 11):
    uv run scripts/cast-stream.py

Pick a device explicitly and give the real stream URL:
    uv run scripts/cast-stream.py --device "Living Room TV" \
        http://192.168.1.20:11/stream.m3u8

Why the LAN IP and not localhost: the Cast device fetches the URL itself, so
`localhost` would point at the TV. Use the address the device can reach.
"""

from __future__ import annotations

import argparse
import socket
import sys
import time

import pychromecast
from pychromecast.controllers.media import MediaStatusListener


def lan_ip() -> str:
    """Best-effort LAN IP of this machine — an address a Cast device can reach."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packets are sent; this just resolves the outbound interface.
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def guess_content_type(url: str) -> str:
    path = url.split("?", 1)[0].lower()
    if path.endswith((".m3u8", ".m3u")):
        return "application/x-mpegurl"
    if path.endswith((".mp3", ".aac", ".m4a", ".ogg", ".wav")):
        return "audio/mpeg"
    if path.endswith(".webm"):
        return "video/webm"
    if path.endswith((".ts", ".m2ts")):
        return "video/mp2t"
    return "video/mp4"


class StatusPrinter(MediaStatusListener):
    """Print the device's playback state as it changes."""

    def new_media_status(self, status):
        if status.player_state:
            title = f" — {status.title}" if status.title else ""
            print(f"  [{status.player_state}]{title}")

    def load_media_failed(self, queue_item_id, error_code):
        print(f"  load_media_failed: error {error_code}", file=sys.stderr)


def select_device(casts, want: str | None):
    """Pick a device by exact name, case-insensitive substring, or host/IP."""
    if not casts:
        print("No Google Cast devices found on this network.", file=sys.stderr)
        return None
    if not want:
        return casts[0]

    needle = want.strip().lower()
    for c in casts:
        if c.name.lower() == needle:
            return c
    for c in casts:
        if needle in c.name.lower():
            return c
    for c in casts:
        if needle in c.cast_info.host.lower():
            return c

    names = ", ".join(c.name for c in casts)
    print(f"No device matched {want!r}. Found: {names}", file=sys.stderr)
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Cast a stream to a Google Cast device.",
    )
    parser.add_argument(
        "url",
        nargs="?",
        help="Stream URL. Defaults to http://<this-machine-lan-ip>:<port>/",
    )
    parser.add_argument(
        "-d", "--device",
        help="Device name or IP (exact, substring, or host). Default: first found.",
    )
    parser.add_argument(
        "-p", "--port", type=int, default=11,
        help="Port used to build the default URL (default: 11).",
    )
    parser.add_argument(
        "-c", "--content-type",
        help="MIME type of the stream. Guessed from the URL when omitted.",
    )
    parser.add_argument(
        "-t", "--timeout", type=float, default=8.0,
        help="Discovery timeout in seconds (default: 8).",
    )
    parser.add_argument(
        "--list", action="store_true",
        help="List cast devices on the network and exit.",
    )
    parser.add_argument(
        "--no-wait", action="store_true",
        help="Return as soon as playback starts instead of streaming status.",
    )
    args = parser.parse_args(argv)

    url = args.url or f"http://{lan_ip()}:{args.port}/"
    content_type = args.content_type or guess_content_type(url)

    casts, browser = pychromecast.get_chromecasts(timeout=args.timeout)
    try:
        if args.list:
            if not casts:
                print("No Google Cast devices found on this network.", file=sys.stderr)
                return 1
            for c in casts:
                model = f" ({c.cast_info.model_name})" if c.cast_info.model_name else ""
                print(f"- {c.name}{model}  {c.cast_info.host}:{c.cast_info.port}")
            return 0

        target = select_device(casts, args.device)
        if target is None:
            return 1

        print(f"Connecting to {target.name} …")
        target.wait()
        controller = target.media_controller
        controller.register_status_listener(StatusPrinter())

        print(f"Casting: {url}")
        print(f"Content-Type: {content_type}")
        controller.play_media(url, content_type)
        controller.block_until_active(timeout=15)

        if args.no_wait:
            return 0

        print("Playing. Press Ctrl+C to stop watching (the stream keeps playing).")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        return 0
    finally:
        browser.stop_discovery()


if __name__ == "__main__":
    raise SystemExit(main())
