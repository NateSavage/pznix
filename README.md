# pznix

NixOS module for running one or more [Project Zomboid](https://projectzomboid.com/)
dedicated servers via [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD).


## Importing This NixOS Flake

Add the input and wire the module into your host's module list - this part is typically just
`flake.nix` itself, with the actual server config living elsewhere alongside the rest of that
host's config:

```nix
{
  inputs.pznix.url = "github:NateSavage/pznix";

  outputs = { self, nixpkgs, pznix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        pznix.nixosModules.default
        ./hosts/myhost/default.nix
      ];
    };
  };
}
```

## Configuring A Server

`pznix.nixosModules.default` just adds the `services.pznix.servers` option - it doesn't require
any particular file layout, so this goes wherever the rest of that host's config lives (e.g.
`hosts/myhost/default.nix` above):

```nix
{ config, ... }:
{
  services.pznix.servers.my-server = {
    # See "Secrets" below.
    joinPasswordFile = config.sops.secrets."zomboid/my-server/join-password".path;
    adminPasswordFile = config.sops.secrets."zomboid/my-server/admin-password".path;

    pauseWhenEmpty = true;

    # Everything else - PVP, player limits, sandbox/difficulty, etc - goes through these two
    # (extraIniSettings from https://pzwiki.net/wiki/Server_settings, extraSandboxSettings from
    # https://pzwiki.net/wiki/Sandbox_options; see the Full Config Example below for more).
    extraIniSettings = {
      PVP = "false";
      MaxPlayers = "16";
    };
    extraSandboxSettings = {
      SleepAllowed = "true";
      SleepNeeded = "false";
    };
  };
}
```

Each entry under `services.pznix.servers` is an independent server instance, keyed by whatever
name you give it (`my-server` above) - that name is also the default for the in-game server
name, data directory, and system user, so a minimal instance can be as short as:

```nix
services.pznix.servers.my-server.adminPasswordFile =
  config.sops.secrets."zomboid/my-server/admin-password".path;
```

## Secrets

Every server needs an admin password file and optionally a join password file. 
Whatever mechanism supplies these files (sops-nix, agenix, plain `environment.etc`, whatever),
**the file must be readable by that instance's `user`** (default`pzserver-<name>`);
sops-nix in particular defaults secrets to `root:root` mode `0400`, so you'll need something like..

```nix
sops.secrets."zomboid/my-server/admin-password" = {
  sopsFile = ./secrets.yaml;
  owner = config.services.pznix.servers.my-server.user;
};
```

## Full Config Example

Every option at its default value (except `adminPasswordFile`, which has none - PZ always
requires one, so a value is filled in here just to make this a complete, valid example):

```nix
services.pznix.servers.my-server = {
  enable = true;
  serverName = "my-server";              # defaults to the instance name ("my-server")
  appId = "380870";
  dataDir = "/var/lib/pznix/my-server";  # defaults to .../<instance name>
  user = "pzserver-my-server";           # defaults to pzserver-<instance name>
  group = "pzserver-my-server";          # defaults to pzserver-<instance name>
  openFirewall = true;
  ports = {
    game = 16261;
    extra = [ { port = 16262; protocol = "udp"; } ];
  };
  memoryLimit = "8G";
  autoUpdate = true;
  joinPasswordFile = null;                                 # no join password required
  adminPasswordFile = /run/secrets/zomboid-example-admin;  # REQUIRED - no default, shown here only
  pauseWhenEmpty = true;
  saveIntervalMinutes = 15;
  extraIniSettings = { 
    PVP = "false";
    MaxPlayers = "16";
    Public = "false";
  };
  extraSandboxSettings = { 
    SleepAllowed = "true";
    SleepNeeded = "false";
  };
  extraArgs = [ ];
  restartSec = 10;
};
```

### Running Multiple Servers On One Host

Just add more entries. Each gets its own systemd service (`pznix-<name>`), user,
group, and data directory automatically, so they don't collide with each other by default - the
one thing you must set yourself is distinct ports per instance:

```nix
services.pznix.servers = {
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

## Known Issues

- The JVM heap size (`-Xmx`) is controlled by PZ's own `ProjectZomboid64.json`, not this module -
  `memoryLimit` here is only the systemd/cgroup `MemoryMax` ceiling around it.
- No beta-branch support (`-beta` app_update flag) - add via a fork or ask for it as a feature.
