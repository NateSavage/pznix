"""pznix preStart.

Installs/updates the game and any configured Workshop content via
steamcmd, regenerates <servername>.ini and <servername>_SandboxVars.lua,
and refreshes the one-time admin-account bootstrap answers file.

Driven entirely by the JSON config at $PZNIX_CONFIG - see module.nix's
mkServer for what it contains and why each field exists.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib import parse, request

GET_COLLECTION_DETAILS_URL = (
    "https://api.steampowered.com/ISteamRemoteStorage/"
    "GetCollectionDetails/v1/"
)
GET_PUBLISHED_FILE_DETAILS_URL = (
    "https://api.steampowered.com/ISteamRemoteStorage/"
    "GetPublishedFileDetails/v1/"
)


def log(server_name: str, message: str) -> None:
    print(f"pznix ({server_name}): {message}", file=sys.stderr)


def read_secret(path: str) -> str:
    # Trailing-newline strip only, matching bash's $(cat file) semantics -
    # a text editor's trailing newline shouldn't become part of the
    # value.
    return Path(path).read_text().rstrip("\n")


def atomic_write(path: Path, content: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content)
    tmp.replace(path)


def steam_api_post(url: str, fields: list[tuple[str, str]]) -> dict:
    data = parse.urlencode(fields).encode()
    req = request.Request(url, data=data)
    with request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def resolve_collection(cid: str) -> list[str]:
    # Collections aren't downloadable content themselves - resolve via
    # Steam's public, keyless Web API into member item IDs first. Raise
    # loud on any error rather than silently treating a bad/inaccessible
    # collection ID as "zero members".
    body = steam_api_post(
        GET_COLLECTION_DETAILS_URL,
        [("collectioncount", "1"), ("publishedfileids[0]", cid)],
    )
    details = body["response"]["collectiondetails"][0]
    if details.get("result") != 1:
        raise RuntimeError(
            f"collection {cid} did not resolve "
            f"(result={details.get('result')})"
        )
    return [c["publishedfileid"] for c in details.get("children", [])]


def fetch_time_updated(ids: list[str]) -> dict[str, int]:
    # Batch-query every resolved item's Steam Workshop time_updated in
    # one request - lets resolve_and_download skip steamcmd entirely for
    # items whose upstream time_updated hasn't moved since we last
    # confirmed downloading them. Only items with result == 1 are kept -
    # anything unresolved (deleted, private, a transient API hiccup) is
    # simply absent, which the caller treats the same as "never
    # confirmed before": always hand it to steamcmd rather than risk
    # skipping a download we can't actually vouch for.
    if not ids:
        return {}
    fields = [("itemcount", str(len(ids)))]
    fields += [
        (f"publishedfileids[{i}]", item_id)
        for i, item_id in enumerate(ids)
    ]
    body = steam_api_post(GET_PUBLISHED_FILE_DETAILS_URL, fields)
    return {
        item["publishedfileid"]: item["time_updated"]
        for item in body["response"]["publishedfiledetails"]
        if item.get("result") == 1
    }


def prune_stale_content(content_dir: Path, keep_ids: set[str]) -> None:
    # Drop anything downloaded under content_dir that isn't in this round's
    # resolved id set - dropped from workshopItems/collectionIds directly,
    # or a collection member Steam removed upstream. steamcmd only ever
    # adds content we ask for; without this, a mod pulled from a
    # collection stays fully installed (and its ID could later get reused
    # for something unrelated and get picked back up by derive_mods) even
    # though it no longer appears in Mods=/WorkshopItems=. Only touches
    # directories that look like a Workshop item ID (all-digits) -
    # content_dir is exclusively ours, but this keeps the blast radius
    # obvious even so.
    if not content_dir.is_dir():
        return
    for entry in content_dir.iterdir():
        if (
            entry.is_dir()
            and entry.name.isdigit()
            and entry.name not in keep_ids
        ):
            shutil.rmtree(entry)


def resolve_and_download(cfg: dict) -> None:
    server = cfg["serverName"]
    paths = cfg["paths"]

    ids = set(cfg["workshopItems"])
    for cid in cfg["collectionIds"]:
        ids |= set(resolve_collection(cid))
    ids -= set(cfg["excludeWorkshopItems"])
    ids = sorted(ids)

    new_times = fetch_time_updated(ids)

    content_dir = Path(paths["workshopContentDir"])
    times_path = Path(paths["workshopTimesFile"])
    old_times: dict[str, int] = {}
    if times_path.exists():
        old_times = json.loads(times_path.read_text())

    # Skip steamcmd only when: the directory is already there, AND this
    # round's API call actually resolved a time_updated for it, AND that
    # time matches what we last confirmed. An unresolved item this round
    # (API hiccup, item briefly private) is never silently treated as
    # "unchanged" - it's always handed to steamcmd rather than risk
    # skipping a download we can't currently vouch for.
    needs_update = [
        item_id for item_id in ids
        if not (content_dir / item_id).is_dir()
        or item_id not in new_times
        or new_times[item_id] != old_times.get(item_id)
    ]

    if needs_update:
        cmd = [
            cfg["steamcmdBin"], "+force_install_dir", cfg["dataDir"],
            "+login", "anonymous",
        ]
        for item_id in needs_update:
            cmd += [
                "+workshop_download_item", cfg["workshopAppId"],
                item_id, "validate",
            ]
        # steamcmd's own exit code isn't trustworthy (known to report
        # success on a failed/partial download) - verified by directory
        # presence below instead.
        subprocess.run(cmd + ["+quit"])

    missing = [i for i in ids if not (content_dir / i).is_dir()]
    if missing:
        raise RuntimeError(
            f"Workshop item(s) missing after download: "
            f"{', '.join(missing)}"
        )

    prune_stale_content(content_dir, set(ids))

    confirmed_times = {i: new_times[i] for i in ids if i in new_times}
    atomic_write(times_path, json.dumps(confirmed_times))
    atomic_write(Path(paths["workshopIdsFile"]), json.dumps(ids))
    log(
        server,
        f"resolved {len(ids)} Workshop item(s), "
        f"{len(needs_update)} needed steamcmd",
    )


def install_and_update(cfg: dict) -> None:
    data_dir = Path(cfg["dataDir"])
    installed_marker = data_dir / ".installed"
    if not cfg["autoUpdate"] and installed_marker.exists():
        return

    subprocess.run([
        cfg["steamcmdBin"], "+force_install_dir", cfg["dataDir"],
        "+login", "anonymous", "+app_update", cfg["appId"], "validate",
        "+quit",
    ], check=True)

    if cfg["workshopItems"] or cfg["collectionIds"]:
        last_error: Exception | None = None
        for attempt in range(1, 4):
            try:
                resolve_and_download(cfg)
                last_error = None
                break
            except Exception as exc:
                # Deliberately broad - a network hiccup, a bad
                # collection ID, or a failed download should all be
                # retried the same way, not crash preStart outright.
                last_error = exc
                if attempt < 3:
                    log(
                        cfg["serverName"],
                        f"Workshop resolution/download incomplete "
                        f"({exc}), retrying "
                        f"(attempt {attempt + 1}/3)...",
                    )
        if last_error is not None:
            log(
                cfg["serverName"],
                "giving up resolving/downloading Workshop items "
                "after 3 attempts",
            )
            raise last_error
    else:
        # No Workshop content configured (any more) - drop whatever was
        # previously downloaded/tracked rather than leaving it orphaned,
        # same as resolve_and_download does for individual items dropped
        # from a still-configured collection.
        prune_stale_content(Path(cfg["paths"]["workshopContentDir"]), set())
        Path(cfg["paths"]["workshopIdsFile"]).unlink(missing_ok=True)
        Path(cfg["paths"]["workshopTimesFile"]).unlink(missing_ok=True)

    installed_marker.touch()


def placate_advanced_animator(cfg: dict) -> None:
    # PZ's AdvancedAnimator unconditionally walks every mod's
    # media/AnimSets and media/actiongroups looking for animation/action
    # definitions, and logs a harmless ERROR for each one that doesn't
    # exist. Steam Workshop drops empty directories on upload, so most
    # mods are missing at least one of these two. Create both (with a
    # placeholder file, so a directory created here never looks "empty"
    # to steamcmd's validate either) under every media/ directory found -
    # this runs every start, independent of autoUpdate, so it also
    # retroactively quiets already-downloaded mods.
    if not (cfg["mods"] or cfg["workshopItems"] or cfg["collectionIds"]):
        return
    scan_dirs = [
        Path(cfg["paths"]["workshopContentDir"]),
        Path(cfg["dataDir"]) / "Zomboid" / "mods",
    ]
    for scan_dir in scan_dirs:
        if not scan_dir.is_dir():
            continue
        for media_dir in scan_dir.rglob("media"):
            if not media_dir.is_dir():
                continue
            for sub in ("AnimSets", "actiongroups"):
                target = media_dir / sub
                if not target.is_dir():
                    target.mkdir(parents=True)
                    (target / "_pznix_placeholder.txt").touch()


def derive_mods(cfg: dict) -> list[str]:
    ids_path = Path(cfg["paths"]["workshopIdsFile"])
    ids = json.loads(ids_path.read_text()) if ids_path.exists() else []
    content_dir = Path(cfg["paths"]["workshopContentDir"])

    discovered: set[str] = set()
    for item_id in ids:
        mods_dir = content_dir / item_id / "mods"
        if mods_dir.is_dir():
            discovered.update(
                p.name for p in mods_dir.iterdir() if p.is_dir()
            )

    exclude = set(cfg["excludeMods"])
    return sorted((discovered | set(cfg["mods"])) - exclude)


def write_ini(cfg: dict) -> None:
    paths = cfg["paths"]
    ini_path = Path(paths["ini"])
    ini_path.parent.mkdir(parents=True, exist_ok=True)

    managed = set(cfg["iniManagedKeys"])
    kept_lines = []
    if ini_path.exists():
        for line in ini_path.read_text().splitlines():
            if line.split("=", 1)[0] not in managed:
                kept_lines.append(line)

    ids_path = Path(paths["workshopIdsFile"])
    workshop_ids = (
        json.loads(ids_path.read_text()) if ids_path.exists() else []
    )

    lines = list(kept_lines)
    if cfg["joinPasswordFile"]:
        lines.append(f"Password={read_secret(cfg['joinPasswordFile'])}")
    if cfg["rconPasswordFile"]:
        lines.append(
            f"RCONPassword={read_secret(cfg['rconPasswordFile'])}"
        )
    lines.append(f"Mods={';'.join(derive_mods(cfg))}")
    lines.append(f"WorkshopItems={';'.join(workshop_ids)}")
    for key, value in cfg["iniSettings"].items():
        lines.append(f"{key}={value}")

    atomic_write(ini_path, "\n".join(lines) + "\n")


def write_sandbox_lua(cfg: dict) -> None:
    lua_path = Path(cfg["paths"]["lua"])
    if not lua_path.exists():
        lua_path.write_text("SandboxVars = {\n}\n")

    sandbox = cfg["sandboxSettings"]
    managed_keys = set(sandbox.keys())

    out_lines = []
    for line in lua_path.read_text().splitlines():
        stripped = line.strip()
        if re.match(r"^SandboxVars\s*=\s*\{", stripped):
            out_lines.append(line)
            for key, value in sandbox.items():
                out_lines.append(f"    {key} = {value},")
            continue
        key_match = re.match(r"^(\w+)\s*=", stripped)
        if key_match and key_match.group(1) in managed_keys:
            continue
        out_lines.append(line)

    atomic_write(lua_path, "\n".join(out_lines) + "\n")


def write_admin_answers(cfg: dict) -> None:
    # PZ asks twice (enter, then confirm) the very first time it creates
    # the world's db - only actually needed then, but written fresh on
    # every start regardless (cheap, and start.py decides whether to
    # actually feed it to PZ's stdin). Created with 0600 from the start
    # (not chmod'd after) so there's no window where it's readable
    # wider.
    admin_pw = read_secret(cfg["adminPasswordFile"])
    answers_path = cfg["paths"]["adminAnswers"]
    fd = os.open(
        answers_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
    )
    with os.fdopen(fd, "w") as f:
        f.write(f"{admin_pw}\n{admin_pw}\n")


def main() -> None:
    cfg = json.loads(Path(os.environ["PZNIX_CONFIG"]).read_text())
    install_and_update(cfg)
    placate_advanced_animator(cfg)
    write_ini(cfg)
    write_sandbox_lua(cfg)
    write_admin_answers(cfg)


if __name__ == "__main__":
    main()
