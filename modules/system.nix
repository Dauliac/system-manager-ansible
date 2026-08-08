{ libExt, rolesDir }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ansible;
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
        name = "ansible";
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
        name = "ansible-runner";
      };

  # Check helper — run after ansible.service and enforce onFailure semantics.
  # Runs on every activation via oneshot; does NOT block activation itself
  # (system-manager doesn't expose an activation hook that can fail switch).
  # A crashed ansible.service will show in `systemctl status ansible` and
  # cascade via ansible-check.service's own failed state.
  checkService =
    if runner == null then
      null
    else
      pkgs.writeShellApplication {
        name = "ansible-check";
        runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
        text = ''
          if systemctl is-failed --quiet ansible.service; then
            echo "services.ansible: ansible.service is in the 'failed' state." >&2
            echo "  Inspect with: journalctl -u ansible -e" >&2
            case "${cfg.onFailure}" in
              fail-activation) exit 1 ;;
              warn)            echo "  (services.ansible.onFailure = warn — continuing)" >&2 ;;
              ignore)          : ;;
            esac
          fi
        '';
      };
in
{
  options.services.ansible = {
    enable = lib.mkEnableOption "system-manager-ansible declarative bootstrap";

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
      description = "Reserved for a future release — currently a no-op on system-manager.";
    };

    markerPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/system-manager-ansible/ansible.done";
      description = "systemd ConditionPathExists=! marker.";
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
        Behaviour of the ancillary ansible-check.service when ansible.service is
        in the 'failed' state. Note: system-manager doesn't expose a way to fail
        the `switch` command from an activation script, so 'fail-activation'
        currently means "ansible-check.service exits non-zero" — the failure is
        visible via `systemctl status ansible-check` but does NOT propagate to
        the deployer's shell.
      '';
    };

    extraSystemdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged verbatim into systemd.services.ansible.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ansible = lib.recursiveUpdate {
      description = "system-manager-ansible: composed ansible playbook (localhost)";
      wantedBy = lib.optional cfg.runOnBoot "multi-user.target";
      after = lib.optionals cfg.runOnBoot [ "network-online.target" ];
      wants = lib.optionals cfg.runOnBoot [ "network-online.target" ];
      unitConfig = lib.optionalAttrs (!cfg.disableMarker) {
        ConditionPathExists = "!${cfg.markerPath}";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runner}/bin/ansible-runner";
        ExecStartPost = "${pkgs.coreutils}/bin/mkdir -p ${dirOf cfg.markerPath} && ${pkgs.coreutils}/bin/touch ${cfg.markerPath}";
      };
    } cfg.extraSystemdConfig;

    # Post-deploy check unit — runs after ansible.service, mirrors its failure.
    systemd.services.ansible-check = lib.mkIf (cfg.onFailure != "ignore") {
      description = "system-manager-ansible: post-deploy failure check";
      after = [ "ansible.service" ];
      wants = [ "ansible.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${checkService}/bin/ansible-check";
      };
    };
  };
}
