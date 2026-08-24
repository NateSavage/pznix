"""pznix daily(-ish) update-check restart.

Only acts if the service is currently running; if configured with RCON
credentials, broadcasts a countdown of in-game warnings via servermsg
before restarting - see module.nix's restartWarningTimes/
restartWarningMessage.

Speaks the Source RCON wire protocol directly over a plain socket rather
than shelling out to a third-party client - it's a small, well-documented
binary protocol, and PZ implements the same one Minecraft/ARK/Rust/etc
use.
"""

from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

PKT_AUTH = 3
PKT_AUTH_RESPONSE = 2
PKT_EXEC_COMMAND = 2


def _read_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("RCON connection closed unexpectedly")
        buf += chunk
    return buf


def _send_packet(
    sock: socket.socket, req_id: int, pkt_type: int, body: str
) -> None:
    payload = (
        struct.pack("<ii", req_id, pkt_type) + body.encode() + b"\x00\x00"
    )
    sock.sendall(struct.pack("<i", len(payload)) + payload)


def _read_packet(sock: socket.socket) -> tuple[int, int, str]:
    size = struct.unpack("<i", _read_exact(sock, 4))[0]
    data = _read_exact(sock, size)
    req_id, pkt_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8", errors="replace")
    return req_id, pkt_type, body


def rcon_command(
    host: str, port: int, password: str, command: str, timeout: float = 5
) -> None:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        _send_packet(sock, 1, PKT_AUTH, password)
        # A well-known Source-RCON quirk: some servers send an empty
        # SERVERDATA_RESPONSE_VALUE (type 0) packet immediately before
        # the real auth response - skip anything that isn't it.
        while True:
            req_id, pkt_type, _ = _read_packet(sock)
            if pkt_type == PKT_AUTH_RESPONSE:
                break
        if req_id == -1:
            raise RuntimeError("RCON authentication failed")
        _send_packet(sock, 2, PKT_EXEC_COMMAND, command)
        _read_packet(sock)


def human_duration(seconds: int) -> str:
    if seconds >= 60 and seconds % 60 == 0:
        minutes = seconds // 60
        return f"{minutes} minute{'' if minutes == 1 else 's'}"
    return f"{seconds} second{'' if seconds == 1 else 's'}"


def send_warnings(cfg: dict) -> None:
    times = sorted(set(cfg["restartWarningTimes"]), reverse=True)
    if not (cfg["rconPasswordFile"] and times):
        return

    password = Path(cfg["rconPasswordFile"]).read_text().rstrip("\n")
    previous: int | None = None
    for offset in times:
        if previous is not None:
            time.sleep(previous - offset)
        message = cfg["restartWarningMessage"].replace(
            "%s", human_duration(offset)
        )
        try:
            rcon_command(
                "127.0.0.1", cfg["rconPort"], password,
                f'servermsg "{message}"',
            )
        except Exception as exc:
            # A warning that fails to send (wrong password, RCON not up
            # yet, a transient connection hiccup) should never block the
            # restart it's warning about.
            print(
                f"pznix ({cfg['serverName']}): restart warning failed: "
                f"{exc}",
                file=sys.stderr,
            )
        previous = offset
    time.sleep(times[-1])


def main() -> None:
    cfg = json.loads(Path(os.environ["PZNIX_CONFIG"]).read_text())
    unit = cfg["unitName"] + ".service"
    systemctl = cfg["systemctlBin"]

    active = subprocess.run(
        [systemctl, "is-active", "--quiet", unit]
    ).returncode == 0
    if not active:
        return

    send_warnings(cfg)
    subprocess.run([systemctl, "try-restart", unit], check=True)


if __name__ == "__main__":
    main()
