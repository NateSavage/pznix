{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.pznix;

  boolStr = b: if b then "true" else "false";

  workshopAppId = "108600"; # project zomboid game client ID

  enabledServers = filterAttrs (_: s: s.enable) cfg.servers;

  # The scripting side of this module - preStart, launch, world-wipe, and the
  # update-check restart - is plain Python now, not Nix-interpolated bash: see
  # ./scripts/*.py. Each is fully static (all per-instance values flow in via
  # the JSON config below, referenced through $PZNIX_CONFIG), so every
  # instance shares the same one build of each script rather than each
  # getting its own copy.
  prestartScript = pkgs.writers.writePython3 "pznix-prestart" { }
    (builtins.readFile ./scripts/prestart.py);
  startScript = pkgs.writers.writePython3 "pznix-start" { }
    (builtins.readFile ./scripts/start.py);
  wipeWorldScript = pkgs.writers.writePython3 "pznix-wipe-world" { }
    (builtins.readFile ./scripts/wipe_world.py);
  updateCheckScript = pkgs.writers.writePython3 "pznix-update-check" { }
    (builtins.readFile ./scripts/update_check.py);

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
          including the plaintext join/RCON passwords in <servername>.ini. Not a risk from unrelated
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

      autoUpdateCheckTime = mkOption {
        type = types.nullOr types.str;
        default = "04:00";
        description = ''
          systemd OnCalendar expression (e.g. "04:00" for daily at 4am, equivalently
          "*-*-* 04:00:00", or "Sun 04:00" for weekly) on which this instance is automatically
          restarted to pick up new game/Workshop updates - reuses the same steamcmd
          validate+update preStart logic that already runs on every service start, so on a day
          with nothing new upstream this is a fast no-op, not a fresh download. Only takes effect
          when autoUpdate = true; set to null to disable proactive checking (updates then only
          apply whenever the service happens to start/restart on its own, e.g. after a crash or
          reboot). Restarting briefly disconnects any connected players - pick your server's
          low-traffic hours. See systemd.time(7) for the full calendar syntax.
        '';
      };

      rconPort = mkOption {
        type = types.port;
        default = 27015;
        description = ''
          RCON port (<servername>.ini RCONPort=) - PZ's remote-admin-console protocol. Used by
          this module (only when rconPasswordFile is set) to broadcast in-game warnings via
          servermsg before an autoUpdateCheckTime restart - see restartWarningTimes. Always
          written to the ini regardless of rconPasswordFile, same as PZ's own default (RCON stays
          disabled as long as RCONPassword is empty). Every instance defaults to the same port -
          like ports.game, give each a distinct one if running more than one server on this
          host. Deliberately never added to openFirewall: RCON is full remote admin access with
          no separate permission levels, this module only ever dials it over localhost, and it
          should never be reachable from outside this host.
        '';
      };

      rconPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the RCON password (<servername>.ini RCONPassword=). Null (the
          default) leaves RCON disabled, matching PZ's own behavior for an empty RCONPassword.
          Must be readable by this instance's `user` - e.g. with sops-nix, set the secret's
          `owner` to match. Setting this is what enables the in-game warnings described under
          restartWarningTimes below; it also just works as an ordinary RCON credential if you
          want to connect yourself with any Source-RCON-compatible client for manual
          administration.
        '';
      };

      restartWarningTimes = mkOption {
        type = types.listOf types.ints.unsigned;
        default = [ 300 60 10 ];
        description = ''
          Seconds before an autoUpdateCheckTime restart to broadcast an in-game warning via
          RCON's servermsg command - one message per offset here, largest first, e.g. the
          default [300 60 10] warns at 5 minutes, 1 minute, and 10 seconds before the restart
          actually happens. Empty list sends no warnings. Only takes effect when
          rconPasswordFile is set - without RCON credentials there's no channel to send a
          warning through, so a scheduled restart just happens immediately and silently, same as
          before this option existed.
        '';
      };

      restartWarningMessage = mkOption {
        type = types.str;
        default = "Server restarting for updates in %s - please find a safe spot!";
        description = ''
          Warning message broadcast in-game (via RCON servermsg) before an autoUpdateCheckTime
          restart, once per configured restartWarningTimes offset. "%s" is replaced with a
          human-readable countdown for that offset (e.g. "5 minutes", "10 seconds").
        '';
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

      mods = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra/manually-placed PZ internal Mod IDs (from each mod's mod.info) to enable, on
          top of whatever's auto-discovered from workshopItems/collectionIds downloads - most
          setups with Workshop mods won't need this. Populates the ini's Mods= list together
          with the auto-discovered set (deduplicated). Useful for a mod you've placed by hand
          under dataDir/Zomboid/mods/<ModID> instead of through the Workshop, or if this is
          the only way you want to enable mods at all (workshopItems/collectionIds both
          empty).
        '';
      };

      excludeMods = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Mod IDs to force-disable even if present among downloaded/auto-discovered mods -
          for when a Workshop item or a collectionIds entry bundles a mod you don't want
          active but still want the rest of that item downloaded.
        '';
      };

      workshopItems = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Steam Workshop item IDs (numeric) to fetch via steamcmd's +workshop_download_item
          before every start (subject to autoUpdate, same as the base game install). Merged
          with whatever collectionIds resolve to (deduplicated), and used to populate the
          ini's WorkshopItems= list. Only public items work - the download uses the same
          anonymous login as the base game install. Downloaded content lands under
          dataDir/steamapps/workshop/content/108600/<id>, alongside the server install
          itself, which PZ resolves automatically. You don't need to separately list each
          item's internal Mod ID - see `mods` above, enabled mods are auto-discovered from
          what's actually downloaded.
        '';
      };

      collectionIds = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Steam Workshop Collection IDs to resolve into their member item IDs before every
          start (subject to autoUpdate), merged with workshopItems above. A collection has no
          downloadable content of its own - steamcmd can't fetch a collection ID directly -
          so this module resolves it first via Steam's public
          ISteamRemoteStorage/GetCollectionDetails Web API (no API key needed for public
          collections) and downloads its member items same as if you'd listed them in
          workshopItems yourself. Only public collections work.
        '';
      };

      excludeWorkshopItems = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Workshop item IDs to drop from workshopItems/collectionIds resolution entirely, before
          steamcmd ever sees them. Different from excludeMods: that only stops an
          already-*downloaded* item's mod from being enabled in Mods=, so it can't help when the
          item itself can't be downloaded at all - a collection doesn't stop listing a member
          just because it went private or got taken down (steamcmd then fails it with "Access
          Denied"), and this module treats any Workshop item it can't confirm downloaded as a
          fatal error, by design (see workshopItems). Without this, one dead collection member
          fails every single start, forever. Add its ID here to keep the rest of the collection
          auto-syncing while you sort out a replacement (or confirm it's gone for good).
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

      startTimeoutSec = mkOption {
        type = types.str;
        default = "30min";
        description = ''
          systemd TimeoutStartSec for this instance's service - how long systemd waits for
          preStart (steamcmd install/update, plus every configured Workshop item's download) and
          the server's own startup before giving up and killing it as failed. systemd's own
          default (90s) is nowhere near enough for a modded install - and since autoUpdate
          re-validates/re-downloads everything on every start by default, not just the first,
          undersizing this risks a start-fail loop on every restart, not just initial setup.
          Accepts systemd time-span syntax (e.g. "30min", "1h", plain seconds) or "infinity" to
          disable the timeout entirely (not recommended - a genuinely hung steamcmd/JVM process
          would then never get killed automatically).
        '';
      };
    };
  };

  # Everything needed to build one instance's systemd units + tmpfiles rules, given its resolved
  # submodule config `s` and its attribute name.
  mkServer = name: s: rec {
    unitName = "pznix-${name}";

    ini = "${s.dataDir}/Zomboid/Server/${s.serverName}.ini";
    lua = "${s.dataDir}/Zomboid/Server/${s.serverName}_SandboxVars.lua";
    adminAnswers = "${s.dataDir}/.admin-answers";
    # Exists once PZ has created the world's db (zombie.network.ServerWorldDatabase) - the
    # one-time signal that the admin account already exists and won't be prompted for again.
    # Confirmed against a live server's actual layout - it's Zomboid/db/<name>.db, a plain file
    # directly under Zomboid/db/, NOT nested under Saves/Multiplayer/<name>/ (that was wrong).
    worldDb = "${s.dataDir}/Zomboid/db/${s.serverName}.db";
    # The actual map/world save (chunk data, structures, zombie population) - separate from
    # worldDb above, which holds accounts and player character data. Both need clearing to
    # generate a genuinely fresh world; see wipeWorldUnit below.
    savesDir = "${s.dataDir}/Zomboid/Saves/Multiplayer/${s.serverName}";
    # Where steamcmd's +workshop_download_item lands content - used to verify each item
    # actually downloaded, since steamcmd is known to sometimes exit 0 on a failed/partial
    # download rather than a nonzero status - and to auto-discover which Mod IDs to enable
    # (each item's mods/<ModID> subdirectory name) without maintaining a separate list.
    workshopContentDir = "${s.dataDir}/steamapps/workshop/content/${workshopAppId}";
    # Persisted, JSON list: the fully resolved (collectionIds expanded + workshopItems) and
    # *verified-downloaded* set of Workshop item IDs from the most recent successful preStart
    # resolution. Read back on every start (even one where autoUpdate skipped re-resolving) to
    # populate the ini's WorkshopItems= and to know what to scan for mods.
    workshopIdsFile = "${s.dataDir}/.workshop-items.json";
    # Persisted, JSON object of id -> time_updated: the Steam Workshop last-modified timestamp
    # we last confirmed each item was downloaded at. Lets prestart.py's resolve_and_download
    # skip steamcmd entirely for an item whose upstream time_updated hasn't moved since - see
    # its docstring for the full story.
    workshopTimesFile = "${s.dataDir}/.workshop-times.json";

    # --- <servername>.ini ---
    # PauseEmpty/SaveWorldEveryMinutes/RCONPort are the only ini settings this module models
    # directly (they affect this module's own behavior, not just gameplay). Everything else -
    # PVP, MaxPlayers, Public, safehouses, etc - goes through extraIniSettings; see its option
    # description and the README for a full example.
    namedIniSettings = {
      PauseEmpty = boolStr s.pauseWhenEmpty;
      SaveWorldEveryMinutes = toString s.saveIntervalMinutes;
      RCONPort = toString s.rconPort;
    };
    # Mods/WorkshopItems are deliberately excluded here even if set via extraIniSettings -
    # both are exclusively owned by the dedicated mods/workshopItems/collectionIds options
    # now, computed at runtime in prestart.py (see workshopIdsFile above): unlike everything
    # else in iniSettings, neither is knowable at Nix eval time, since Mods depends on what's
    # actually discovered under downloaded Workshop content and WorkshopItems depends on
    # collectionIds resolution.
    iniSettings = removeAttrs (namedIniSettings // s.extraIniSettings) [ "Mods" "WorkshopItems" ];
    # ini keys prestart.py owns outright - stripped from any pre-existing ini before it rewrites
    # them, so a key removed from config (or a stale RCONPassword left over from before
    # rconPasswordFile was set) doesn't linger forever.
    iniManagedKeys = (optional (s.joinPasswordFile != null) "Password")
      ++ (optional (s.rconPasswordFile != null) "RCONPassword")
      ++ [ "Mods" "WorkshopItems" ]
      ++ (builtins.attrNames iniSettings);

    # --- <servername>_SandboxVars.lua ---
    # This module doesn't model any sandbox/difficulty settings directly - it's all
    # extraSandboxSettings (see its option description and the README for a full example).
    sandboxSettings = s.extraSandboxSettings;

    # However long update_check.py's warning countdown runs before it actually restarts -
    # the largest configured restartWarningTimes offset (the first warning fires immediately,
    # the restart lands exactly that many seconds later), or 0 with no warnings configured.
    # Nix-side only because TimeoutStartSec has to be known before the script ever runs.
    maxWarningSec =
      if s.restartWarningTimes == [ ] then 0
      else foldl' (a: b: if b > a then b else a) 0 s.restartWarningTimes;

    # Single source of truth for every per-instance value the Python scripts need - see each
    # script's own docstring for how it's used. Kept as one file (rather than one per script) so
    # there's exactly one place that has to stay in sync with what the scripts actually read.
    configFile = pkgs.writeText "${unitName}-config.json" (builtins.toJSON {
      inherit unitName;
      inherit (s) serverName appId autoUpdate rconPort;
      inherit workshopAppId;
      dataDir = toString s.dataDir;
      steamcmdBin = "${pkgs.steamcmd}/bin/steamcmd";
      systemctlBin = "${pkgs.systemd}/bin/systemctl";
      workshopItems = s.workshopItems;
      collectionIds = s.collectionIds;
      excludeWorkshopItems = s.excludeWorkshopItems;
      mods = s.mods;
      excludeMods = s.excludeMods;
      inherit iniSettings iniManagedKeys sandboxSettings;
      paths = {
        inherit ini lua adminAnswers worldDb savesDir;
        inherit workshopContentDir workshopIdsFile workshopTimesFile;
      };
      joinPasswordFile =
        if s.joinPasswordFile == null then null else toString s.joinPasswordFile;
      adminPasswordFile = toString s.adminPasswordFile;
      rconPasswordFile =
        if s.rconPasswordFile == null then null else toString s.rconPasswordFile;
      inherit (s) restartWarningTimes restartWarningMessage extraArgs;
    });

    tmpfilesRules = [
      "d ${s.dataDir} 0750 ${s.user} ${s.group} -"
    ];

    unit = {
      description = "Project Zomboid dedicated server (${s.serverName})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # coreutils/gnutar/gzip are for start-server.sh itself (PZ's own vendored script, not
      # ours) - our own logic no longer shells out to anything via $PATH lookup: steamcmd and
      # systemctl are both invoked by absolute store path (see configFile above).
      path = with pkgs; [ coreutils gnutar gzip ];

      environment = {
        HOME = s.dataDir;
        PZNIX_CONFIG = "${configFile}";
      };

      preStart = "exec ${prestartScript}";
      script = "exec ${startScript}";

      serviceConfig = {
        Type = "simple";
        User = s.user;
        Group = s.group;
        WorkingDirectory = s.dataDir;

        Restart = "on-failure";
        RestartSec = s.restartSec;
        TimeoutStartSec = s.startTimeoutSec;

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

    # Explicitly-triggered only (`systemctl start pznix-<name>-wipe-world`) - never WantedBy
    # anything, never runs on its own. Deliberately NOT a config option (e.g.
    # `wipeWorldOnNextStart = true`): with Restart = "on-failure" on the main unit, a persisted
    # flag like that risks nuking the world on every crash-restart if you forget to flip it back
    # off, rather than the one deliberate wipe you meant. `conflicts`+`after` on the main service
    # means starting this always stops the live server first (never deletes out from under a
    # running world) and orders the wipe after that stop completes; it deliberately does NOT
    # restart the main service afterward - `systemctl start pznix-<name>` is a separate,
    # deliberate step once you're ready to generate the fresh world.
    wipeWorldUnit = {
      description = "Wipe saved world data for Project Zomboid dedicated server (${s.serverName}) - DESTRUCTIVE, run manually";
      conflicts = [ "${unitName}.service" ];
      after = [ "${unitName}.service" ];

      environment.PZNIX_CONFIG = "${configFile}";
      script = "exec ${wipeWorldScript}";

      serviceConfig = {
        Type = "oneshot";
        User = s.user;
        Group = s.group;

        # Same rationale as the main unit's sandboxing - restricting writes to just dataDir means
        # even a mistake here can't reach anywhere outside this instance's own data.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ s.dataDir ];
      };
    };

    # Proactive daily(-ish) update check - see autoUpdateCheckTime above. Only actually wired up
    # (via updateCheckServers below) when autoUpdate is on and autoUpdateCheckTime isn't null;
    # built unconditionally here regardless since Nix is lazy and it costs nothing on its own.
    updateCheckTimer = {
      description = "Timer: check for updates for Project Zomboid dedicated server (${s.serverName})";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = s.autoUpdateCheckTime;
        Persistent = true; # catch up on a missed run (e.g. host was off) at next boot
        Unit = "${unitName}-update-check.service";
      };
    };

    # try-restart (not restart/start): only acts if the service is already running, so a
    # currently-stopped instance doesn't get started just to be updated, and there's no one to
    # warn either - it'll pick up whatever's current the next time it starts on its own anyway,
    # via the same preStart. Runs as root (the default for a systemd service), since restarting a
    # *different* unit (and, for the warnings, reading rconPasswordFile) needs privileges this
    # instance's own unprivileged `user` doesn't have. The warning countdown itself (RCON
    # servermsg broadcasts, see restartWarningTimes/restartWarningMessage) lives entirely in
    # update_check.py.
    updateCheckService = {
      description = "Check for and apply updates for Project Zomboid dedicated server (${s.serverName})";

      environment.PZNIX_CONFIG = "${configFile}";
      script = "exec ${updateCheckScript}";

      serviceConfig = {
        Type = "oneshot";
        # Generous enough to cover the full warning countdown end-to-end (see maxWarningSec)
        # plus slack for the restart itself.
        TimeoutStartSec = "${toString (maxWarningSec + 120)}s";
      };
    };
  };

  builtServers = mapAttrs mkServer enabledServers;

  # Subset of enabledServers that actually get a daily update-check timer wired up - excludes
  # anything with autoUpdate = false (nothing for a restart to usefully pick up) or
  # autoUpdateCheckTime = null (explicitly opted out).
  updateCheckServers = filterAttrs (_: s: s.autoUpdate && s.autoUpdateCheckTime != null) enabledServers;
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

    systemd.services =
      (mapAttrs' (name: built: nameValuePair "pznix-${name}" built.unit) builtServers)
      // (mapAttrs' (name: built: nameValuePair "pznix-${name}-wipe-world" built.wipeWorldUnit) builtServers)
      // (mapAttrs' (name: _: nameValuePair "pznix-${name}-update-check" builtServers.${name}.updateCheckService) updateCheckServers);

    systemd.timers =
      mapAttrs' (name: _: nameValuePair "pznix-${name}-update-check" builtServers.${name}.updateCheckTimer) updateCheckServers;
  };
}
