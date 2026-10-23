# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Agent memory: a place on the owner's box where an AI agent keeps its memory.
#
#   - One folder per agent under /var/lib/cloudunit/agent-memory/agents/<name>. An agent
#     reaches only its own folder, through the API on :8790 (modules/agent-memory.py).
#   - The owner creates and revokes agents in Settings > Agents. Each agent gets a token
#     shown once; only its SHA-256 is stored. No agents = nothing gets in.
#   - journal/ inside each folder is append-only through the API.
#   - The folder rides the nightly box-to-box backup (replication-sender.nix), and the
#     backup box refuses every delete, so what an agent wrote survives the agent.
#
# OFF by default: with keephaven.agentMemory.enable = false nothing here is in the
# image and every existing output builds byte-identical (checked by comparing the
# prod toplevel store path before and after). It turns on per flake output.
#
# Privilege: the server runs as kh-memory, which can write only the memory folder.
# Settings (cloudunit-web) reaches the owner commands through one sudo NOPASSWD
# wrapper, the same pattern as every other privileged Settings action.
{ config, lib, pkgs, ... }:
let
  cfg = config.keephaven.agentMemory;
  dataDir = "/var/lib/cloudunit";
  memDir = "${dataDir}/agent-memory";
  user = "kh-memory";

  cli = pkgs.writeShellScriptBin "agent-memory" ''
    exec ${pkgs.python3}/bin/python3 ${./agent-memory.py} "$@"
  '';

  # The owner's commands, run as root through sudo from Settings. Validates its own
  # arguments (Settings is not trusted to), fixes ownership after every change so the
  # server can read the registry and write the agent's folder, and logs every branch.
  admin = pkgs.writeShellScriptBin "keephaven-agent-memory-admin" ''
    set -u
    co=${pkgs.coreutils}/bin
    say() { ${pkgs.util-linux}/bin/logger -t keephaven-agent-memory-admin -- "$*"; }
    name_ok() { printf '%s' "$1" | ${pkgs.gnugrep}/bin/grep -Eqx '[a-z0-9][a-z0-9-]{0,31}'; }
    fix_owner() {
      $co/mkdir -p ${memDir}/agents || return 1
      $co/chown ${user}:${user} ${memDir} ${memDir}/agents || return 1
      $co/chmod 0750 ${memDir} ${memDir}/agents || return 1
      if [ -f ${memDir}/agents.json ]; then
        $co/chown root:${user} ${memDir}/agents.json && $co/chmod 0640 ${memDir}/agents.json || return 1
      fi
      if [ -n "''${1:-}" ] && [ -d "${memDir}/agents/$1" ]; then
        $co/chown -R ${user}:${user} "${memDir}/agents/$1" || return 1
      fi
    }
    cmd="''${1:-}"
    case "$cmd" in
      add)
        n="''${2:-}"; q="''${3:-1024}"; ro="''${4:-}"
        name_ok "$n" || { say "add refused: bad name"; echo "ERROR: name must be 1-32 of a-z 0-9 -" >&2; exit 2; }
        printf '%s' "$q" | ${pkgs.gnugrep}/bin/grep -Eqx '[0-9]{1,7}' || { say "add refused: bad quota"; echo "ERROR: quota" >&2; exit 2; }
        set -- add --data ${memDir} "$n" --quota-mb "$q"
        [ "$ro" = "ro" ] && set -- "$@" --read-only
        if TOKEN="$(${cli}/bin/agent-memory "$@")"; then
          if fix_owner "$n"; then
            say "added agent $n quota=''${q}MB ''${ro:-rw}"
            printf '%s\n' "$TOKEN"
          else
            say "added agent $n but ownership fix FAILED"; echo "ERROR: ownership" >&2; exit 4
          fi
        else
          rc=$?; say "add $n failed rc=$rc"; exit "$rc"
        fi ;;
      revoke|delete)
        n="''${2:-}"
        name_ok "$n" || { say "$cmd refused: bad name"; echo "ERROR: bad name" >&2; exit 2; }
        if ${cli}/bin/agent-memory "$cmd" --data ${memDir} "$n" && fix_owner; then
          say "$cmd $n ok"
        else
          rc=$?; say "$cmd $n failed rc=$rc"; exit 3
        fi ;;
      list)
        fix_owner >/dev/null 2>&1 || say "list: ownership fix failed"
        ${cli}/bin/agent-memory list --data ${memDir} ;;
      *)
        echo "usage: keephaven-agent-memory-admin add NAME [QUOTA_MB] [ro] | revoke NAME | delete NAME | list" >&2; exit 2 ;;
    esac
  '';
in
{
  options.keephaven.agentMemory = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Agent memory on :8790. Off by default; existing images are unchanged when off.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8790;
      description = "Port for the agent memory API.";
    };
    adminWrapper = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Store path of the owner-command wrapper, for Settings' sudo grant.";
    };
  };

  config = lib.mkMerge [
    { keephaven.agentMemory.adminWrapper = "${admin}/bin/keephaven-agent-memory-admin"; }
    (lib.mkIf cfg.enable {
      users.users.${user} = {
        isSystemUser = true;
        group = user;
        description = "Keephaven agent memory (unprivileged)";
      };
      users.groups.${user} = { };

      systemd.tmpfiles.rules = [
        "d ${memDir} 0750 ${user} ${user} -"
        "d ${memDir}/agents 0750 ${user} ${user} -"
      ];

      environment.systemPackages = [ cli admin ];

      systemd.services.keephaven-agent-memory = {
        description = "Keephaven agent memory API";
        after = [ "network.target" "systemd-tmpfiles-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = dataDir;
        serviceConfig = {
          Type = "simple";
          User = user;
          Group = user;
          ExecStart = "${cli}/bin/agent-memory serve --data ${memDir} --port ${toString cfg.port}";
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0027";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ memDir ];
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
          SystemCallFilter = [ "@system-service" ];
          SystemCallArchitectures = "native";
        };
      };

      networking.firewall.allowedTCPPorts = [ cfg.port ];
    })
  ];
}
