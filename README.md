# project-zomboid-server

A declarative, self-contained NixOS module for running a single [Project Zomboid](https://projectzomboid.com/)
dedicated server via SteamCMD.

Built from scratch after a long debugging session against
[ALH477/steamcmd-servers](https://github.com/ALH477/steamcmd-servers), which turned out broken in
enough different ways - some in the flake itself, some in assumptions that don't hold on NixOS,
some in the game's own launch scripts - that it was easier to write a clean, PZ-specific module
than keep patching around someone else's. Every workaround below was discovered the hard way, in
production, one crash log at a time. Nothing here is speculative.

## Usage

```nix
{
  inputs.project-zomboid-server.url = "github:<you>/project-zomboid-server";

  outputs = { self, nixpkgs, project-zomboid-server, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        project-zomboid-server.nixosModules.default
        ({ config, ... }: {
          services.project-zomboid-server = {
            enable = true;
            serverName = "my-server";
            openFirewall = true;

            # See "Secrets" below.
            joinPasswordFile = config.sops.secrets."zomboid/server-password".path;
            adminPasswordFile = config.sops.secrets."zomboid/admin-password".path;

            pvp = false;
            pauseWhenEmpty = true;
            sleepAllowed = true;
            sleepNeeded = false;

            extraIniSettings = {
              MaxPlayers = "16";
            };
          };
        })
      ];
    };
  };
}
```

See `module.nix` for the full option list (ports, memory limit, autoUpdate, extraArgs, etc).

## Secrets

Two secret files are needed - a join password (optional) and an admin password (required, since
PZ always prompts for one on first boot with no way to skip it, and this module doesn't support
running without one). Whatever mechanism supplies these files (sops-nix, agenix, plain
`environment.etc`, whatever), **the file must be readable by the service's user** (default
`pzserver`). sops-nix in particular defaults secrets to `root:root` mode `0400`, so you'll need:

```nix
sops.secrets."zomboid/admin-password" = {
  sopsFile = ./secrets.yaml;
  owner = config.services.project-zomboid-server.user;
};
```

## Why this module looks the way it does

Every one of these was a distinct failure discovered against the upstream module; each is
load-bearing, not decorative:

1. **No multi-server abstraction.** One module, one server, one `enable`. The upstream module has
   a *second*, separate `enable` nested under each `servers.<name>` submodule, apart from the
   module-wide one - forget to set it and the server silently never starts: no error, no systemd
   unit, nothing to even look at. Not reproducing that footgun here; if you need more than one
   server, import this module twice under different service names, or ask for that as a feature.

2. **Single `dataDir`, not a data-dir/install-dir split.** The server process's `$HOME` needs to
   be writable - steamcmd wants `~/.local`, PZ itself wants `~/Zomboid` - but `ProtectSystem=strict`
   hardening only grants write access to paths explicitly listed in `ReadWritePaths`. The upstream
   module sets `HOME` to a shared top-level directory but only whitelists each server's *own*
   install subdirectory plus a shared `logs/` dir - leaving `$HOME` itself read-only
   (`mkdir: cannot create directory '.../.local': Read-only file system`). Here there's just one
   directory for everything, and it's the only thing in `ReadWritePaths`, so this class of bug
   can't recur.

3. **`RestrictNamespaces = false`.** `pkgs.steamcmd` is a `buildFHSEnv` wrapper that shells out to
   `bwrap` (bubblewrap) to build its FHS sandbox, which needs to create a Linux user namespace.
   Restricting namespaces blocks that outright:
   `bwrap: No permissions to create a new namespace, likely because the kernel does not allow
   non-privileged user namespaces.` (The kernel almost certainly does allow it - this is systemd's
   own seccomp filter, not a kernel-level restriction.)

4. **`SystemCallArchitectures = "native x86"`.** steamcmd's FHS sandbox runs a 32-bit (i386)
   `ldconfig` to build a 32-bit library cache (Steam/Source-engine-family servers commonly need
   32-bit compat libs). `"native"`-only permits just the 64-bit syscall ABI, so seccomp kills the
   32-bit process the instant it makes a syscall: `ldconfig killed by signal 31` (SIGSYS), with a
   coredump showing `ELF object binary architecture: Intel 80386`.

5. **A `/bin/bash` compatibility symlink.** NixOS has no `/bin/bash` (bash lives in the Nix
   store); PZ's downloaded `start-server.sh` hardcodes `#!/bin/bash`, so without this it fails
   with `bad interpreter: No such file or directory`.

6. **`programs.nix-ld`.** PZ ships a prebuilt, dynamically-linked JRE (`jre64/bin/java`) built for
   generic Linux, not NixOS. Without `nix-ld` it fails to load at all - NixOS's `stub-ld`
   placeholder prints `Could not start dynamically linked executable ... see
   https://nix.dev/permalink/stub-ld` - which `start-server.sh`'s own check swallows (redirects
   to `/dev/null`) and reports as the wildly misleading `Only 64bit is supported`. It has nothing
   to do with 64-bit-ness; the check is just "did `java -version` exit 0."

7. **Admin password fed via `StandardInput=file:`, not a CLI flag.** On first boot PZ prompts
   *interactively*, twice (`Enter new administrator password:` then `Confirm the password:`), and
   under systemd stdin is `/dev/null` by default, so it crashes with
   `java.util.NoSuchElementException: No line found`. A `-adminpassword` launch flag exists on
   PZ's side, but launch args get baked verbatim into the **world-readable** Nix store, so a
   secret passed that way would leak to any local user - stdin doesn't have that problem, and
   isn't visible via `/proc/<pid>/cmdline` the way argv is. `preStart` builds a small answers
   file from the secret (the password, written twice) each run.

8. **A stdin placeholder file via `systemd.tmpfiles.rules`.** `StandardInput=file:...` applies to
   *every* exec step of the unit, including `preStart` - which is what generates that same file's
   real content each run. Without pre-creating an empty placeholder, `preStart`'s own stdin-open
   fails (`Failed to set up standard input: No such file or directory`, systemd exit `208/STDIN`)
   before `preStart` ever executes a single line.

9. **`grep -v ... || true`.** These scripts run under `set -e` (NixOS wraps generated
   `preStart`/`script` bodies that way). `grep -v PATTERN file` exits `1` if *every* line matches
   the pattern - i.e. nothing survives the inversion - which happens here the first time the ini
   only contains the handful of keys this module manages (before PZ has had a chance to populate
   the rest of its own defaults). An unguarded `grep -v` failing here silently aborts the whole
   script with zero output, which is a nasty one to debug blind.

10. **`-servername` as two separate list elements, not one string.** `lib.escapeShellArgs` quotes
    *each list element* as a single shell word, preserving embedded spaces - so
    `[ "-servername myserver" ]` becomes one argv token `-servername myserver` (literally
    containing a space), not two separate arguments. PZ's launcher doesn't recognize that as the
    flag it's expecting, and silently falls back to its default profile name instead of erroring -
    so this is a bug you'd only notice by realizing your world never actually persists under the
    name you asked for. This module builds `executableArgs`-equivalent output correctly from a
    plain `serverName` string option, so it isn't possible to make this mistake through it.

## Limitations

- Single server instance only (point 1 above - deliberate, not a TODO).
- Anonymous SteamCMD login only (fine for PZ specifically - the dedicated server depot doesn't
  require an authenticated Steam account).
- The JVM heap size (`-Xmx`) is controlled by PZ's own `ProjectZomboid64.json`, not this module -
  `memoryLimit` here is only the systemd/cgroup `MemoryMax` ceiling around it.
- No beta-branch support (`-beta` app_update flag) - add via a fork or ask for it as a feature.
