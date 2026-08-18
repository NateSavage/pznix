# project-zomboid-server

A declarative NixOS module for running one or more [Project Zomboid](https://projectzomboid.com/)
dedicated servers via SteamCMD.

Built from scratch after a long debugging session against
[ALH477/steamcmd-servers](https://github.com/ALH477/steamcmd-servers), which turned out broken in
enough different ways - some in the flake itself, some in assumptions that don't hold on NixOS,
some in the game's own launch scripts - that it was easier to write a clean, PZ-specific module
than keep patching around someone else's. Every workaround below was discovered the hard way, in
production, one crash log at a time. Nothing here is speculative.

## Usage

```nix
{
  inputs.project-zomboid-server.url = "github:<you>/pznix";

  outputs = { self, nixpkgs, project-zomboid-server, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        project-zomboid-server.nixosModules.default
        ({ config, ... }: {
          services.project-zomboid-server.servers.my-server = {
            openFirewall = true;

            # See "Secrets" below.
            joinPasswordFile = config.sops.secrets."zomboid/my-server/join-password".path;
            adminPasswordFile = config.sops.secrets."zomboid/my-server/admin-password".path;

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

Each entry under `services.project-zomboid-server.servers` is an independent server instance,
keyed by whatever name you give it (`my-server` above) - that name is also the default for the
in-game server name, data directory, and system user, so a minimal instance can be as short as:

```nix
services.project-zomboid-server.servers.my-server.adminPasswordFile =
  config.sops.secrets."zomboid/my-server/admin-password".path;
```

### Running multiple servers on one host

Just add more entries. Each gets its own systemd service (`project-zomboid-server-<name>`), user,
group, and data directory automatically, so they don't collide with each other by default - the
one thing you must set yourself is distinct ports per instance:

```nix
services.project-zomboid-server.servers = {
  main = {
    ports.game = 16261;
    ports.extra = [ { port = 16262; protocol = "udp"; } ];
    adminPasswordFile = config.sops.secrets."zomboid/main/admin-password".path;
  };
  modded = {
    ports.game = 16263;
    ports.extra = [ { port = 16264; protocol = "udp"; } ];
    adminPasswordFile = config.sops.secrets."zomboid/modded/admin-password".path;
    extraIniSettings.Mods = "SomeMod";
  };
};
```

## Secrets

Every instance needs an admin password file (required - see point 7 below) and optionally a join
password file. Whatever mechanism supplies these files (sops-nix, agenix, plain
`environment.etc`, whatever), **the file must be readable by that instance's `user`** (default
`pzserver-<name>`) - sops-nix in particular defaults secrets to `root:root` mode `0400`, so you'll
need something like:

```nix
sops.secrets."zomboid/my-server/admin-password" = {
  sopsFile = ./secrets.yaml;
  owner = config.services.project-zomboid-server.servers.my-server.user;
};
```

## Maximal config example

Every option, explicitly set to its own default (except `adminPasswordFile`, which has none - PZ
always requires one, so a value is filled in here just to make this a complete, valid example).
For instance key `"example"`:

```nix
services.project-zomboid-server.servers.example = {
  enable = true;                                          # merely defining this entry is enough
  serverName = "example";                                 # defaults to the instance name ("example")
  appId = "380870";
  dataDir = "/var/lib/project-zomboid-server/example";    # defaults to .../<instance name>
  user = "pzserver-example";                              # defaults to pzserver-<instance name>
  group = "pzserver-example";                             # defaults to pzserver-<instance name>
  openFirewall = false;
  ports = {
    game = 16261;
    extra = [ { port = 16262; protocol = "udp"; } ];
  };
  memoryLimit = "8G";
  autoUpdate = true;
  joinPasswordFile = null;                                # no join password required
  adminPasswordFile = /run/secrets/zomboid-example-admin;  # REQUIRED - no default, shown here only
  pvp = false;
  pauseWhenEmpty = true;
  saveIntervalMinutes = 15;
  sleepAllowed = true;
  sleepNeeded = false;
  extraIniSettings = { };
  extraSandboxSettings = { };
  extraArgs = [ ];
  restartSec = 10;
};
```

## Why this module looks the way it does

Every one of these was a distinct failure discovered against the upstream module; each is
load-bearing, not decorative:

1. **Per-instance `enable` defaults to `true`.** The upstream module has a module-wide `enable`
   *and* a second, separate `enable` nested under each `servers.<name>` submodule - forget the
   second one and the server silently never starts: no error, no systemd unit, nothing to even
   look at. Here there's exactly one `enable` per instance, and it defaults on, so merely
   defining a `servers.<name> = { ... }` block is enough to run it. `enable = false` still exists
   for keeping a config around without running it.

2. **Per-instance `dataDir`/`user`/`group`, not a data-dir/install-dir split.** The server
   process's `$HOME` needs to be writable - steamcmd wants `~/.local`, PZ itself wants
   `~/Zomboid` - but `ProtectSystem=strict` hardening only grants write access to paths
   explicitly listed in `ReadWritePaths`. The upstream module sets `HOME` to a shared top-level
   directory but only whitelists each server's *own* install subdirectory plus a shared `logs/`
   dir, leaving `$HOME` itself read-only
   (`mkdir: cannot create directory '.../.local': Read-only file system`). Here there's just one
   directory per instance for everything, it's the only thing in that instance's
   `ReadWritePaths`, and it (along with the default user/group) is scoped to the instance's name
   by default, so multiple instances don't collide with each other either.

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

10. **`-servername` built from a plain string option, not hand-assembled.** `lib.escapeShellArgs`
    quotes *each list element* as a single shell word, preserving embedded spaces - so writing
    `executableArgs = [ "-servername myserver" ]` yourself becomes one argv token
    `-servername myserver` (literally containing a space), not two separate arguments. PZ's
    launcher doesn't recognize that as the flag it's expecting, and silently falls back to its
    default profile name instead of erroring - so it's a bug you'd only notice by realizing your
    world never actually persists under the name you asked for. This module builds the launch
    command correctly from `serverName` internally, so it isn't possible to make this mistake
    through it.

## Limitations

- Anonymous SteamCMD login only (fine for PZ specifically - the dedicated server depot doesn't
  require an authenticated Steam account).
- The JVM heap size (`-Xmx`) is controlled by PZ's own `ProjectZomboid64.json`, not this module -
  `memoryLimit` here is only the systemd/cgroup `MemoryMax` ceiling around it.
- No beta-branch support (`-beta` app_update flag) - add via a fork or ask for it as a feature.
- No automatic port allocation across instances - if you run more than one server, you pick
  distinct ports for each yourself (see "Running multiple servers on one host" above).
