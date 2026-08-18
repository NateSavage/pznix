{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.pznix;

  boolStr = b: if b then "true" else "false";

  enabledServers = filterAttrs (_: s: s.enable) cfg.servers;

  portSubmodule = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        description = "Port number.";
      };
      protocol = mkOption {
        type = types.enum [ "tcp" "udp" ];
        default = "udp";
        description = "Protocol for this port.";
      };
    };
  };

  serverSubmodule = { name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When true this server will start automatically.
        '';
      };

      serverName = mkOption {
        type = types.str;
        default = name;
        description = ''
          Server/profile name - becomes -servername on the launch command and determines the
          config file names under dataDir/Zomboid/Server/ (<name>.ini, <name>_SandboxVars.lua).
          Defaults to the attribute name this server is defined under.
        '';
      };

      appId = mkOption {
        type = types.str;
        default = "380870";
        description = "Steam App ID for the dedicated server depot.";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/pznix/${name}";
        defaultText = literalExpression ''"/var/lib/pznix/''${name}"'';
        description = ''
          Single directory holding everything for this instance: the installed game files, $HOME
          (and therefore PZ's own Zomboid/ profile directory), and internal state.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "pzserver-${name}";
        defaultText = literalExpression ''"pzserver-''${name}"'';
        description = ''
          User this instance runs as. Defaults to a per-instance user (rather than one shared
          "pzserver" account) so multiple servers don't collide - if you deliberately point two
          instances at the same user, you're responsible for keeping their dataDirs from
          overlapping too.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "pznix";
        description = ''
          Group this instance runs as. Defaults to a single shared "pznix" group across every
          server. each server's dataDir is 0750 (owner + group readable/traversable), so sharing one group means every
          pznix-managed server's own process can read into every other one's dataDir too,
          including the plaintext join password in <servername>.ini. Not a risk from unrelated
          system users, but it does mean pzservers aren't isolated from each other. Give each server its own distinct
          group (e.g."pznix-''${name}") for full multi server isolation.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = true;
        description = "Open this instance's configured ports in the firewall.";
      };

      ports = {
        game = mkOption {
          type = types.port;
          default = 16261;
          description = ''
            Main game UDP port. Every instance defaults to the same port - when running more
            than one server on this host, you must give each a distinct port yourself.
          '';
        };
        extra = mkOption {
          type = types.listOf portSubmodule;
          default = [ { port = 16262; protocol = "udp"; } ];
          description = "Additional ports this instance uses alongside its main game port.";
        };
      };

      memoryLimit = mkOption {
        type = types.nullOr types.str;
        default = "8G";
        description = ''
          systemd MemoryMax for this instance's service (a hard cgroup cap). Distinct from the
          JVM's own -Xmx heap size, which PZ controls itself via ProjectZomboid64.json (not
          managed by this module) - keep this comfortably above whatever -Xmx is set to.
        '';
      };

      autoUpdate = mkOption {
        type = types.bool;
        default = true;
        description = "When true, run steamcmd validate+update on every service start.";
      };

      joinPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the password required to join (<servername>.ini Password=).
          Null means no password. Must be readable by this instance's `user` - e.g. with
          sops-nix, set the secret's `owner` to match.
        '';
      };

      adminPasswordFile = mkOption {
        type = types.path;
        description = ''
          Path to a file containing the password for PZ's built-in "admin" account on this
          instance. Required: PZ prompts for this interactively on stdin the first time it
          creates that account, and this module answers that prompt from this file rather than
          support running without one. Must be readable by this instance's `user`.
        '';
      };

      pauseWhenEmpty = mkOption {
        type = types.bool;
        default = true;
        description = "Stop world time when no players are connected.";
      };

      saveIntervalMinutes = mkOption {
        type = types.ints.unsigned;
        default = 15;
        description = "Periodic autosave interval, in minutes.";
      };

      extraIniSettings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { PVP = "false"; MaxPlayers = "16"; Public = "true"; };
        description = ''
          Additional/override <servername>.ini keys not covered by a named option above - this is
          the primary way to configure most server settings (PVP, MaxPlayers, Public, safehouses,
          etc). See the Project Zomboid wiki's server settings page for available keys:
          https://pzwiki.net/wiki/Server_settings
        '';
      };

      extraSandboxSettings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { SleepAllowed = "true"; SleepNeeded = "false"; Zombies = "3"; };
        description = ''
          SandboxVars.lua keys (difficulty, loot, XP, zombie population, sleep, etc) - this is the
          primary way to configure world/gameplay settings, this module doesn't model any of them
          as named options. Values are inserted as literal Lua, so booleans/numbers should be
          given unquoted (e.g. "3", "true"), strings quoted (e.g. "\"foo\""). See the Project
          Zomboid wiki's sandbox options page for available keys:
          https://pzwiki.net/wiki/Sandbox_options
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments appended to the launch command, after -servername <name>.";
      };

      restartSec = mkOption {
        type = types.int;
        default = 10;
        description = "Seconds to wait before restarting after a crash.";
      };
    };
  };

  # Everything needed to build one instance's systemd unit + tmpfiles rules, given its resolved
  # submodule config `s` and its attribute name.
  mkServer = name: s: rec {
    ini = "${s.dataDir}/Zomboid/Server/${s.serverName}.ini";
    lua = "${s.dataDir}/Zomboid/Server/${s.serverName}_SandboxVars.lua";
    adminAnswers = "${s.dataDir}/.admin-answers";
    # Exists once PZ has created the world's db (zombie.network.ServerWorldDatabase) - the
    # one-time signal that the admin account already exists and won't be prompted for again.
    # Confirmed against a live server's actual layout - it's Zomboid/db/<name>.db, a plain file
    # directly under Zomboid/db/, NOT nested under Saves/Multiplayer/<name>/ (that was wrong).
    worldDb = "${s.dataDir}/Zomboid/db/${s.serverName}.db";

    # --- <servername>.ini ---
    # PauseEmpty/SaveWorldEveryMinutes are the only ini settings this module models directly
    # (they affect this module's own behavior, not just gameplay). Everything else - PVP,
    # MaxPlayers, Public, safehouses, etc - goes through extraIniSettings; see its option
    # description and the README for a full example.
    namedIniSettings = {
      PauseEmpty = boolStr s.pauseWhenEmpty;
      SaveWorldEveryMinutes = toString s.saveIntervalMinutes;
    };
    iniSettings = namedIniSettings // s.extraIniSettings;
    iniManagedKeys = (optional (s.joinPasswordFile != null) "Password") ++ (builtins.attrNames iniSettings);
    iniKeepFilter = concatStringsSep "|" iniManagedKeys;
    # Shell-quoted "KEY=VALUE" words, one per printf arg in preStart - deliberately not a
    # heredoc, since Nix's multi-line-string dedent doesn't play well with those.
    iniStaticArgs = concatMapStringsSep " " escapeShellArg
      (mapAttrsToList (k: v: "${k}=${v}") iniSettings);

    # --- <servername>_SandboxVars.lua ---
    # This module doesn't model any sandbox/difficulty settings directly - it's all
    # extraSandboxSettings (see its option description and the README for a full example).
    # sandboxSettings can legitimately be empty (nothing set), which iniKeepFilter above never
    # is (it always has at least Password/PauseEmpty/SaveWorldEveryMinutes) - the awk rule below
    # is written to tolerate that.
    sandboxSettings = s.extraSandboxSettings;
    sandboxKeyFilter = concatStringsSep "|" (builtins.attrNames sandboxSettings);
    sandboxPrintStmts = concatStringsSep " "
      (mapAttrsToList (k: v: ''print "    ${k} = ${v},";'') sandboxSettings);

    tmpfilesRules = [
      "d ${s.dataDir} 0750 ${s.user} ${s.group} -"
    ];

    unit = {
      description = "Project Zomboid dedicated server (${s.serverName})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [ coreutils gawk gnugrep gnutar gzip steamcmd ];

      environment.HOME = s.dataDir;

      preStart = ''
        if [ "${boolStr s.autoUpdate}" = "true" ] || [ ! -f "${s.dataDir}/.installed" ]; then
          ${pkgs.steamcmd}/bin/steamcmd +force_install_dir "${s.dataDir}" +login anonymous +app_update ${s.appId} validate +quit
          touch "${s.dataDir}/.installed"
        fi

        mkdir -p "$(dirname "${ini}")"

        # --- <servername>.ini ---
        ${optionalString (s.joinPasswordFile != null) ''
          join_pw="$(cat "${s.joinPasswordFile}")"
        ''}
        {
          if [ -f "${ini}" ]; then
            grep -v -E '^(${iniKeepFilter})=' "${ini}" || true
          fi
          ${optionalString (s.joinPasswordFile != null) ''printf 'Password=%s\n' "$join_pw"''}
          printf '%s\n' ${iniStaticArgs}
        } > "${ini}.tmp"
        mv "${ini}.tmp" "${ini}"

        # --- <servername>_SandboxVars.lua ---
        if [ ! -f "${lua}" ]; then
          printf 'SandboxVars = {\n}\n' > "${lua}"
        fi
        awk '
          /^[ \t]*SandboxVars[ \t]*=[ \t]*\{/ { print; ${sandboxPrintStmts} next }
          ${optionalString (sandboxSettings != { }) ''/^[ \t]*(${sandboxKeyFilter})[ \t]*=/ { next }''}
          { print }
        ' "${lua}" > "${lua}.tmp"
        mv "${lua}.tmp" "${lua}"

        # --- admin account bootstrap answers (PZ asks twice: enter, then confirm) ---
        # Only actually needed the very first time the world's db is created - PZ only prompts
        # for this once. Written unconditionally anyway (cheap, mode 0600 owner-only, and
        # rewritten fresh every start), but only actually fed to the server's stdin when the
        # world db doesn't exist yet - see script below.
        admin_pw="$(cat "${s.adminPasswordFile}")"
        ( umask 077; printf '%s\n%s\n' "$admin_pw" "$admin_pw" > "${adminAnswers}" )
      '';

      script = ''
        cd "${s.dataDir}"
        # PZ only prompts for the admin password on stdin the *first* time it creates the
        # world's db (zombie.network.ServerWorldDatabase) - once that db file exists, it won't
        # prompt again. Feeding the answers file unconditionally on every start (as this used
        # to) meant that on every restart *after* the first, those two leftover lines got read
        # by PZ's general server-console command reader instead and logged verbatim to the
        # journal ("command entered via server console (System.in): '<password>'") - i.e. the
        # real admin password in plaintext in the log, every restart, forever. Only redirect
        # stdin from the answers file when the db doesn't exist yet.
        if [ -f "${worldDb}" ]; then
          exec ./start-server.sh -servername ${escapeShellArg s.serverName} ${escapeShellArgs s.extraArgs} < /dev/null
        else
          exec ./start-server.sh -servername ${escapeShellArg s.serverName} ${escapeShellArgs s.extraArgs} < "${adminAnswers}"
        fi
      '';

      serviceConfig = {
        Type = "simple";
        User = s.user;
        Group = s.group;
        WorkingDirectory = s.dataDir;

        Restart = "on-failure";
        RestartSec = s.restartSec;

        StandardOutput = "journal";
        StandardError = "journal";

        MemoryMax = mkIf (s.memoryLimit != null) s.memoryLimit;

        # --- Sandboxing ---
        # Standard hardening, with two deliberate exceptions PZ/steamcmd need to run at all -
        # see the README for the full story of how each was discovered.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # the JVM needs to JIT-compile

        # pkgs.steamcmd is a buildFHSEnv wrapper that shells out to bwrap (bubblewrap) to build
        # its FHS sandbox, which needs to create a Linux user namespace - restricting namespaces
        # blocks that outright ("bwrap: No permissions to create a new namespace").
        RestrictNamespaces = false;

        # steamcmd's FHS sandbox runs a 32-bit (i386) ldconfig to build its 32-bit library
        # cache. "native"-only permits just the 64-bit syscall ABI, so seccomp kills the 32-bit
        # process on its first syscall (SIGSYS).
        SystemCallArchitectures = "native x86";

        ReadWritePaths = [ s.dataDir ];
      };
    };
  };

  builtServers = mapAttrs mkServer enabledServers;
in
{
  options.services.pznix.servers = mkOption {
    type = types.attrsOf (types.submodule serverSubmodule);
    default = { };
    description = ''
      Project Zomboid dedicated server instances to run, keyed by an arbitrary instance name
      (used by default to derive the systemd unit name, data directory, user, and PZ server
      profile name - all independently overridable per instance; see the `group` option for why
      it isn't in that list). Each entry with `enable = true` (the default) gets its own fully
      independent systemd service, user, and data directory, so multiple servers can run on one
      host without colliding, as long as you give each a distinct port.
    '';
  };

  config = mkIf (enabledServers != { }) {

    systemd.tmpfiles.rules =
      (concatLists (mapAttrsToList (_: built: built.tmpfilesRules) builtServers))
      ++ [
        # NixOS has no /bin/bash (bash lives in the Nix store) - PZ's downloaded
        # start-server.sh hardcodes "#!/bin/bash", so provide the standard NixOS compatibility
        # symlink for it. Host-wide; only needs doing once regardless of instance count.
        "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
      ];

    users.users = mapAttrs' (_: s: nameValuePair s.user {
      isSystemUser = true;
      group = s.group;
      home = s.dataDir;
      createHome = true;
      description = "Project Zomboid dedicated server (${s.serverName})";
    }) enabledServers;

    users.groups = mapAttrs' (_: s: nameValuePair s.group { }) enabledServers;

    # PZ ships a prebuilt, dynamically-linked JRE (jre64/bin/java) built for generic Linux, not
    # NixOS. Without nix-ld it fails to load at all - NixOS's stub-ld placeholder ("Could not
    # start dynamically linked executable ... see https://nix.dev/permalink/stub-ld"), which
    # start-server.sh's own architecture check silently swallows and reports as the misleading
    # "Only 64bit is supported" (it has nothing to do with 64-bit-ness). Host-wide; only needs
    # doing once regardless of instance count.
    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc.lib # libstdc++.so.6, libgcc_s.so.1 - needed by most JVMs
        zlib             # libz.so.1 - used by the JVM's jar/zip handling
      ];
    };

    networking.firewall = {
      allowedUDPPorts = concatMap
        (s: if s.openFirewall then
          [ s.ports.game ] ++ (map (p: p.port) (filter (p: p.protocol == "udp") s.ports.extra))
        else [ ])
        (attrValues enabledServers);
      allowedTCPPorts = concatMap
        (s: if s.openFirewall then
          (map (p: p.port) (filter (p: p.protocol == "tcp") s.ports.extra))
        else [ ])
        (attrValues enabledServers);
    };

    systemd.services = mapAttrs' (name: built: nameValuePair "pznix-${name}" built.unit) builtServers;
  };
}
