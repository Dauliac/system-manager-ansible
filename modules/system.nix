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

  # Submodule for each role invocation.
  # freeformType = anything so disk-role-specific fields (repos, packages, etc.)
  # pass through without needing dynamic option-tree injection.
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
              description = "Coarse ordering hint; lower runs earlier. Ties broken by name.";
            };
            tasks = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
              description = "Inline ansible task definitions (as Nix attrsets). If non-empty and no disk role of this name exists, this becomes an inline role.";
            };
            handlers = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
              description = "Inline handler definitions.";
            };
            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Soft ordering deps — run after these roles if they're present.";
            };
            before = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Soft ordering deps — run before these roles if present.";
            };
            requires = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Hard deps — eval fails if listed role isn't declared. Implies 'after'.";
            };
            checkable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this role's tasks are safe under ansible-playbook --check in the nix sandbox.";
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
        - match a disk role directory under roles/ (invocation), or
        - be freeform with non-empty .tasks (inline role authored in Nix), or
        - both (hybrid: disk role plus inline extras).
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
      description = "Run the unit synchronously during activation.";
    };

    markerPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/system-manager-ansible/ansible.done";
      description = "systemd ConditionPathExists=! marker. When present, unit skips.";
    };

    disableMarker = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, no marker gate — the unit runs on every trigger.";
    };

    onFailure = lib.mkOption {
      type = lib.types.enum [ "fail-activation" "warn" "ignore" ];
      default = "fail-activation";
      description = "Post-deploy hook behaviour when ansible.service is in the failed state.";
    };

    extraSystemdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged verbatim into the generated systemd.services.ansible attrset.";
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

    system.activationScripts.ansible-check = lib.stringAfter [ "users" ] ''
      # Only meaningful after the unit has actually been (re)generated.
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-failed --quiet ansible.service 2>/dev/null; then
          echo "services.ansible: ansible.service is in the 'failed' state." >&2
          echo "  Inspect with: journalctl -u ansible -e" >&2
          case "${cfg.onFailure}" in
            fail-activation) exit 1 ;;
            warn)            echo "  (services.ansible.onFailure = warn — continuing)" >&2 ;;
            ignore)          : ;;
          esac
        fi
      fi
    '';
  };
}
