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

Keep an eye on what the Project Zomboid instance is doing through the terminal on your server with `journalctl -u pznix-YOUR-SERVER-NAME -f`.

## Secrets

Every server needs an admin password file, I reccomend you use a secrets management tool like [SOPS](https://github.com/mic92/sops-nix) to create and manage the file so that it never accidently ends up visible somewhere it shouldn't be. But you can just create a file somewhere and point the config at it so long as the user that's created for your server has read permission for the file.

```bash
sudo mkdir -p /run/secrets
printf '%s' 'your-admin-password' | sudo tee /run/secrets/zomboid-admin-password > /dev/null
sudo chown nobody:pznix /run/secrets/zomboid-admin-password
sudo chmod 0400 /run/secrets/zomboid-admin-password
```

```nix
services.pznix.servers.my-server.adminPasswordFile = "/run/secrets/zomboid-admin-password";
```

## Detailed Config Example

```nix
services.pznix.servers.my-server = {
  enable = true;
  serverName = "my-server";              # defaults to the instance name ("my-server")
  appId = "380870";
  dataDir = "/var/lib/pznix/my-server";  # defaults to .../<instance name>
  user = "pzserver-my-server";           # defaults to pzserver-<instance name>
  group = "pznix";                       # shared across every instance by default - see below
  openFirewall = true;
  ports = {
    game = 16261;
    extra = [ { port = 16262; protocol = "udp"; } ];
  };
  memoryLimit = "8G";
  autoUpdate = true;
  joinPasswordFile = null;
  adminPasswordFile = /run/secrets/zomboid-admin-password;  # REQUIRED, there is no default
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

Don't forget to forward the ports on your firewall, Project Zomboid does also seem to support UPNP.

### Running Multiple Servers On One Host

You can declare as many servers as you like, each will have it's own systemd service (`pznix-<my-server>`), user,
and data directory automatically. You only need to set unique ports and an admin password for each one.

Note that `group` defaults to a single shared `pznix` group across *every* instance (not
per-instance like `user`) - see that option's description for what that trades away.

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
- Server instances share a group by default, you can assign them to separate groups, but by default if a Project Zomboid server was exploited, it could read the plaintext configuration files of your other server instances hosted on the same machine.
^ this was intentional to make configuration of shared secrets easier for nix noobs, but I'm on the fence about if it was actually a good idea.
