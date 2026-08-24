"""pznix world wipe.

Destructive and explicitly-triggered only - never run automatically,
only via `systemctl start <unitName>-wipe-world`. See module.nix's
wipeWorldUnit for why this is a separate unit rather than a config flag.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path


def main() -> None:
    cfg = json.loads(Path(os.environ["PZNIX_CONFIG"]).read_text())
    paths = cfg["paths"]
    name = cfg["serverName"]

    print(
        f"pznix ({name}): wiping world - {paths['savesDir']} and "
        f"{paths['worldDb']}*",
        file=sys.stderr,
    )
    shutil.rmtree(paths["savesDir"], ignore_errors=True)
    for suffix in ("", "-wal", "-shm"):
        try:
            os.remove(paths["worldDb"] + suffix)
        except FileNotFoundError:
            pass
    print(
        f"pznix ({name}): world wiped - start {cfg['unitName']} to "
        f"generate a fresh one",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
