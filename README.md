# pznix

NixOS module for running one or more [Project Zomboid](https://projectzomboid.com/)
dedicated servers via [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD).


## Importing This NixOS Flake
Or how to import any NixOS flake.

Add as an input for your flake, and pass the module down to your host config.

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

you can also import a flake without exposing it as an output.

```nix
outputs = { self, nixpkgs, ... }: {
                        # ^ no longer declared as an output
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        inputs.pznix.nixosModules.default
        # ^ now the flake needs to be referenced from the flake's input
        ./hosts/myhost/default.nix
      ];
    };
  };
```

## Configuring A Server
Now that you've passed the pznix module from the flake into your host's configuration you can setup the module as you like.

```nix
{ config, ... }:
{
  # your server is enabled by default when defined
  services.pznix.servers.my-server = {
    # See "Secrets" below. all Project Zomboid Servers require an admin password.
    adminPasswordFile = config.sops.secrets."zomboid/my-server/admin-password".path;

    pauseWhenEmpty = true;

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

## Secrets

Every server needs an admin password file, and optionally a join password file.
**The file must be readable by that instance's `user`** (default `pzserver-<name>`) - and must
**not** be something Nix writes as plaintext itself (`environment.etc.<name>.text`, a
`systemd.tmpfiles.rules` entry with an inline argument, etc) - those land the secret in the
world-readable Nix store, the exact problem described in point 7 of "Why this module looks the
way it does" above.

The simplest way to avoid that, with no secrets-management tool at all: create the file directly
on the host, outside of Nix, and just point the option at its path.

```bash
install -d -m 0750 -o pzserver-my-server -g pzserver-my-server /var/lib/pznix-secrets
printf '%s' 'your-admin-password' > /var/lib/pznix-secrets/my-server-admin
chown pzserver-my-server:pzserver-my-server /var/lib/pznix-secrets/my-server-admin
chmod 0400 /var/lib/pznix-secrets/my-server-admin
```

```nix
services.pznix.servers.my-server.adminPasswordFile = "/var/lib/pznix-secrets/my-server-admin";
```

The tradeoff: this file isn't reproduced by your flake the way the rest of the config is - if you
reprovision the host from scratch, you have to recreate it by hand. If you'd rather have secrets
survive a full rebuild without a manual step, use a real secrets tool instead (sops-nix, agenix,
etc) - see that tool's own docs for how to grant a specific NixOS user read access to a decrypted
secret (with sops-nix, that's the secret's `owner` field).

## Detailed Config Example

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

You can declare as many servers as you like, each will have it's own systemd service (`pznix-<my-server>`), user,
group, and data directory automatically. You only need to set unique ports and an admin password for each one.

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
