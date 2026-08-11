{ libExt, rolesDir }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ansnix;
  roleDefs = libExt.discoverRoles rolesDir;

  roleSubmodule = lib.types.submoduleWith {
    modules = [
      (
        { name, ... }:
        {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Include this role in the composed playbook.";
            };
            priority = lib.mkOption {
              type = lib.types.int;
              default = 100;
              description = "Coarse ordering hint; lower runs earlier.";
            };
            tasks = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
              description = "Inline ansible task definitions.";
            };
            handlers = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
              description = "Inline handler definitions.";
            };
            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Soft ordering deps.";
            };
            before = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Soft ordering deps, reverse direction.";
            };
            requires = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Hard deps — eval fails if missing.";
            };
            checkable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Safe under ansible-playbook --check.";
            };
          };
        }
      )
    ];
  };

  composed =
    if cfg.roles == { } then
      null
    else
      libExt.composePlaybook {
        inherit pkgs;
        name = "ansnix";
        roles = cfg.roles;
        inherit roleDefs;
        become = true;
        extraVars = cfg.vars;
      };

  runner =
    if composed == null then
      null
    else
      libExt.mkPlaybookRunner {
        inherit pkgs;
        package = cfg.package;
        playbookFile = composed.playbookFile;
        extraVarsFile = composed.extraVarsFile;
        rolesPath = composed.rolesPath;
        name = "ansnix-runner";
      };

  checkService =
    if runner == null then
      null
    else
      pkgs.writeShellApplication {
        name = "ansnix-check";
        runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
        text = ''
          on_failure=${lib.escapeShellArg cfg.onFailure}
          if systemctl is-failed --quiet ansnix.service; then
            echo "ansnix: ansnix.service is in the 'failed' state." >&2
            echo "  Inspect with: journalctl -u ansnix -e" >&2
            case "$on_failure" in
              fail-activation) exit 1 ;;
              warn)            echo "  (ansnix.onFailure = warn — continuing)" >&2 ;;
              ignore)          : ;;
            esac
          fi
        '';
      };
in
{
  options.ansnix = {
    enable = lib.mkEnableOption "ansnix — Nix-native ansible bootstrap for localhost";

    package = lib.mkPackageOption pkgs "ansible" { };

    roles = lib.mkOption {
      type = lib.types.attrsOf roleSubmodule;
      default = { };
      description = ''
        Roles to compose into the ansible playbook. Each attribute name may:
        - match a disk role directory under roles/,
        - be freeform with non-empty .tasks (inline role),
        - or both (hybrid).
      '';
    };

    vars = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Module-level extra vars rendered to JSON and passed via --extra-vars.";
    };

    runOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install wantedBy = multi-user.target on the generated unit.";
    };

    runOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Reserved — currently a no-op on system-manager.";
    };

    markerPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ansnix/done";
      description = ''
        Path of the convergence marker file. After a successful run,
        ansnix.service writes the current runner's /nix/store path into this
        file. On next trigger, systemd's ExecCondition compares the stored
        path to the current one — matching skips the run (already converged),
        mismatching (new role, ansible bump, ansnix upgrade) re-runs the
        playbook. Set `disableMarker = true` to bypass the gate entirely.
      '';
    };

    disableMarker = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, no marker gate — unit runs on every trigger.";
    };

    onFailure = lib.mkOption {
      type = lib.types.enum [ "fail-activation" "warn" "ignore" ];
      default = "fail-activation";
      description = ''
        Behaviour of the companion ansnix-check.service when ansnix.service is
        in the 'failed' state. Note: system-manager doesn't expose an activation
        hook that can fail `switch`, so 'fail-activation' currently means
        "ansnix-check.service exits non-zero" — visible via `systemctl status
        ansnix-check` but does NOT propagate to the deployer's shell.
      '';
    };

    extraSystemdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged verbatim into systemd.services.ansnix.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ansnix = lib.recursiveUpdate {
      description = "ansnix: composed ansible playbook (localhost, oneshot)";
      wantedBy = lib.optional cfg.runOnBoot "multi-user.target";
      after = lib.optionals cfg.runOnBoot [ "network-online.target" ];
      wants = lib.optionals cfg.runOnBoot [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Hash-based convergence gate: skip the run when the marker file's
        # contents exactly match the current runner's /nix/store path. Any
        # change to composed roles, ansnix itself, or the ansible package
        # flips the store path so the exit code becomes 0 → systemd runs
        # ExecStart. Missing marker → cat prints nothing → mismatch → run.
        # Marker being a directory (from earlier deploys with the buggy
        # shell-less ExecStartPost) → cat fails → mismatch → run, then
        # ExecStartPost's rm -rf cleans up. Set `disableMarker = true` to
        # bypass the gate and force a run on every trigger.
        ExecStart = "${runner}/bin/ansnix-runner";
        ExecStartPost = [
          "${pkgs.bash}/bin/bash -c 'rm -rf ${cfg.markerPath} && mkdir -p ${dirOf cfg.markerPath} && printf %s ${runner} > ${cfg.markerPath}'"
        ];
      } // lib.optionalAttrs (!cfg.disableMarker) {
        ExecCondition = "${pkgs.bash}/bin/bash -c 'test \"$(cat ${cfg.markerPath} 2>/dev/null)\" != \"${runner}\"'";
      };
    } cfg.extraSystemdConfig;

    systemd.services.ansnix-check = lib.mkIf (cfg.onFailure != "ignore") {
      description = "ansnix: post-deploy failure check";
      after = [ "ansnix.service" ];
      wants = [ "ansnix.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${checkService}/bin/ansnix-check";
      };
    };
  };
}
