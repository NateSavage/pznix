"""pznix launch script.

Feeds the one-time admin-account bootstrap answers to start-server.sh's
stdin only the first time the world's db doesn't exist yet - PZ only
prompts for the admin password once, and reading the answers file on
every later start would get those two leftover lines read by PZ's own
server-console command reader instead and logged verbatim (the real
admin password, in plaintext, every restart). See prestart.py's
write_admin_answers for the file itself.

Replaces this process outright (os.execv), same as the shell `exec` this
used to be, so systemd keeps tracking the real server process rather
than a Python process sitting on top of it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


def main() -> None:
    cfg = json.loads(Path(os.environ["PZNIX_CONFIG"]).read_text())
    os.chdir(cfg["dataDir"])

    world_db_exists = Path(cfg["paths"]["worldDb"]).exists()
    stdin_path = (
        os.devnull if world_db_exists else cfg["paths"]["adminAnswers"]
    )
    stdin_fd = os.open(stdin_path, os.O_RDONLY)
    os.dup2(stdin_fd, 0)
    os.close(stdin_fd)

    args = [
        "./start-server.sh", "-servername", cfg["serverName"],
        *cfg["extraArgs"],
    ]
    os.execv(args[0], args)


if __name__ == "__main__":
    main()
