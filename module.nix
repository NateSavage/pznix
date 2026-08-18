{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.project-zomboid-server;

  boolStr = b: if b then "true" else "false";

  ini = "${cfg.dataDir}/Zomboid/Server/${cfg.serverName}.ini";
  lua = "${cfg.dataDir}/Zomboid/Server/${cfg.serverName}_SandboxVars.lua";
  adminAnswers = "${cfg.dataDir}/.admin-answers";

  # --- <servername>.ini ---
  namedIniSettings = {
    PVP = boolStr cfg.pvp;
    PauseEmpty = boolStr cfg.pauseWhenEmpty;
    SaveWorldEveryMinutes = toString cfg.saveIntervalMinutes;
  };
  iniSettings = namedIniSettings // cfg.extraIniSettings;
  iniManagedKeys = (optional (cfg.joinPasswordFile != null) "Password") ++ (builtins.attrNames iniSettings);
  iniKeepFilter = concatStringsSep "|" iniManagedKeys;
  # Shell-quoted "KEY=VALUE" words, one per printf arg in preStart - deliberately not a heredoc,
  # since Nix's multi-line-string dedent doesn't play well with those.
  iniStaticArgs = concatMapStringsSep " " escapeShellArg
    (mapAttrsToList (k: v: "${k}=${v}") iniSettings);

  # --- <servername>_SandboxVars.lua ---
  namedSandboxSettings = {
    SleepAllowed = boolStr cfg.sleepAllowed;
    SleepNeeded = boolStr cfg.sleepNeeded;
  };
  sandboxSettings = namedSandboxSettings // cfg.extraSandboxSettings;
  sandboxKeyFilter = concatStringsSep "|" (builtins.attrNames sandboxSettings);
  sandboxPrintStmts = concatStringsSep " "
    (mapAttrsToList (k: v: ''print "    ${k} = ${v},";'') sandboxSettings);

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
in
{
  options.services.project-zomboid-server = {
    enable = mkEnableOption "a declarative Project Zomboid dedicated server";

    serverName = mkOption {
      type = types.str;
      default = "servertest";
      description = ''
        Server/profile name - becomes -servername on the launch command and determines the
        config file names under dataDir/Zomboid/Server/ (<name>.ini, <name>_SandboxVars.lua).
      '';
    };

    appId = mkOption {
      type = types.str;
      default = "380870";
      description = "Steam App ID for the dedicated server depot.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/project-zomboid-server";
      description = ''
        Single directory holding everything: the installed game files, $HOME (and therefore
        PZ's own Zomboid/ profile directory), and internal state. Deliberately not split into
        separate "install dir" vs "home dir" locations - see the README for why that split
        caused real problems upstream.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "pzserver";
      description = "User the server runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "pzserver";
      description = "Group the server runs as.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the configured ports in the firewall.";
    };

    ports = {
      game = mkOption {
        type = types.port;
        default = 16261;
        description = "Main game UDP port.";
      };
      extra = mkOption {
        type = types.listOf portSubmodule;
        default = [ { port = 16262; protocol = "udp"; } ];
        description = "Additional ports PZ uses alongside the main game port.";
      };
    };

    memoryLimit = mkOption {
      type = types.nullOr types.str;
      default = "8G";
      description = ''
        systemd MemoryMax for the service (a hard cgroup cap). Distinct from the JVM's own
        -Xmx heap size, which PZ controls itself via ProjectZomboid64.json (not managed by this
        module) - keep this comfortably above whatever -Xmx is set to.
      '';
    };

    autoUpdate = mkOption {
      type = types.bool;
      default = true;
      description = "Run steamcmd validate+update on every service start, not just the first.";
    };

    joinPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the password required to join (<servername>.ini Password=).
        Null means no password. Must be readable by services.project-zomboid-server.user - e.g.
        with sops-nix, set `owner = config.services.project-zomboid-server.user;` on the secret.
      '';
    };

    adminPasswordFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the password for PZ's built-in "admin" account. Required: PZ
        prompts for this interactively on stdin the first time it creates that account, and this
        module answers that prompt from this file rather than support running without one. Must
        be readable by services.project-zomboid-server.user (see joinPasswordFile).
      '';
    };

    pvp = mkOption {
      type = types.bool;
      default = false;
      description = "Allow player-vs-player damage.";
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

    sleepAllowed = mkOption {
      type = types.bool;
      default = true;
      description = "Allow players to sleep in beds.";
    };

    sleepNeeded = mkOption {
      type = types.bool;
      default = false;
      description = "Require players to sleep periodically to avoid fatigue penalties.";
    };

    extraIniSettings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { MaxPlayers = "16"; Public = "true"; };
      description = "Additional/override <servername>.ini keys not covered by a named option above.";
    };

    extraSandboxSettings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { Zombies = "3"; };
      description = ''
        Additional/override SandboxVars.lua keys not covered by a named option above (difficulty,
        loot, XP, etc). Values are inserted as literal Lua, so booleans/numbers should be given
        unquoted (e.g. "3", "true"), strings quoted (e.g. "\"foo\"").
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

  config = mkIf cfg.enable {

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      # StandardInput=file:... (in the service below) applies to *every* exec step of the unit,
      # including preStart - which is what writes this file's real content each run. Without a
      # placeholder, preStart's own stdin-open fails ("No such file or directory", systemd exit
      # 208/STDIN) before preStart ever runs. `f` only creates it if missing, so it doesn't
      # clobber preStart's write on later starts.
      "f ${adminAnswers} 0600 ${cfg.user} ${cfg.group} -"
      # NixOS has no /bin/bash (bash lives in the Nix store) - PZ's downloaded start-server.sh
      # hardcodes "#!/bin/bash", so provide the standard NixOS compatibility symlink for it.
      "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      description = "Project Zomboid dedicated server";
    };
    users.groups.${cfg.group} = { };

    # PZ ships a prebuilt, dynamically-linked JRE (jre64/bin/java) built for generic Linux, not
    # NixOS. Without nix-ld it fails to load at all - NixOS's stub-ld placeholder ("Could not
    # start dynamically linked executable ... see https://nix.dev/permalink/stub-ld"), which
    # start-server.sh's own architecture check silently swallows and reports as the misleading
    # "Only 64bit is supported" (it has nothing to do with 64-bit-ness).
    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc.lib # libstdc++.so.6, libgcc_s.so.1 - needed by most JVMs
        zlib             # libz.so.1 - used by the JVM's jar/zip handling
      ];
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedUDPPorts = [ cfg.ports.game ]
        ++ (map (p: p.port) (filter (p: p.protocol == "udp") cfg.ports.extra));
      allowedTCPPorts = map (p: p.port) (filter (p: p.protocol == "tcp") cfg.ports.extra);
    };

    systemd.services.project-zomboid-server = {
      description = "Project Zomboid dedicated server (${cfg.serverName})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [ coreutils gawk gnugrep gnutar gzip steamcmd ];

      environment.HOME = cfg.dataDir;

      preStart = ''
        if [ "${boolStr cfg.autoUpdate}" = "true" ] || [ ! -f "${cfg.dataDir}/.installed" ]; then
          ${pkgs.steamcmd}/bin/steamcmd +force_install_dir "${cfg.dataDir}" +login anonymous +app_update ${cfg.appId} validate +quit
          touch "${cfg.dataDir}/.installed"
        fi

        mkdir -p "$(dirname "${ini}")"

        # --- <servername>.ini ---
        ${optionalString (cfg.joinPasswordFile != null) ''
          join_pw="$(cat "${cfg.joinPasswordFile}")"
        ''}
        {
          if [ -f "${ini}" ]; then
            grep -v -E '^(${iniKeepFilter})=' "${ini}" || true
          fi
          ${optionalString (cfg.joinPasswordFile != null) ''printf 'Password=%s\n' "$join_pw"''}
          printf '%s\n' ${iniStaticArgs}
        } > "${ini}.tmp"
        mv "${ini}.tmp" "${ini}"

        # --- <servername>_SandboxVars.lua ---
        if [ ! -f "${lua}" ]; then
          printf 'SandboxVars = {\n}\n' > "${lua}"
        fi
        awk '
          /^[ \t]*SandboxVars[ \t]*=[ \t]*\{/ { print; ${sandboxPrintStmts} next }
          /^[ \t]*(${sandboxKeyFilter})[ \t]*=/ { next }
          { print }
        ' "${lua}" > "${lua}.tmp"
        mv "${lua}.tmp" "${lua}"

        # --- admin account bootstrap answers (PZ asks twice: enter, then confirm) ---
        admin_pw="$(cat "${cfg.adminPasswordFile}")"
        ( umask 077; printf '%s\n%s\n' "$admin_pw" "$admin_pw" > "${adminAnswers}" )
      '';

      script = ''
        cd "${cfg.dataDir}"
        exec ./start-server.sh -servername ${escapeShellArg cfg.serverName} ${escapeShellArgs cfg.extraArgs}
      '';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;

        Restart = "on-failure";
        RestartSec = cfg.restartSec;

        StandardInput = "file:${adminAnswers}";
        StandardOutput = "journal";
        StandardError = "journal";

        MemoryMax = mkIf (cfg.memoryLimit != null) cfg.memoryLimit;

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

        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
