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
            enable = lib.mkOption { type = lib.types.bool; default = true; };
            priority = lib.mkOption { type = lib.types.int; default = 100; };
            tasks = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
            handlers = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
            after = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            before = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            requires = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            checkable = lib.mkOption { type = lib.types.bool; default = false; };
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
        become = false;
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

  xdgStateHome = "\${XDG_STATE_HOME:-$HOME/.local/state}";
in
{
  options.services.ansible = {
    enable = lib.mkEnableOption "system-manager-ansible (user-context)";
    package = lib.mkPackageOption pkgs "ansible" { };
    roles = lib.mkOption {
      type = lib.types.attrsOf roleSubmodule;
      default = { };
    };
    vars = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    runOnBoot = lib.mkOption { type = lib.types.bool; default = true; };
    runOnActivation = lib.mkOption { type = lib.types.bool; default = false; };
    markerPath = lib.mkOption {
      type = lib.types.str;
      default = "%S/system-manager-ansible/ansible.done";
    };
    disableMarker = lib.mkOption { type = lib.types.bool; default = false; };
    onFailure = lib.mkOption {
      type = lib.types.enum [ "fail-activation" "warn" "ignore" ];
      default = "fail-activation";
    };
    extraSystemdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.ansible = lib.recursiveUpdate {
      Unit = {
        Description = "system-manager-ansible: composed ansible playbook (user, localhost)";
      } // lib.optionalAttrs (!cfg.disableMarker) {
        ConditionPathExists = "!${cfg.markerPath}";
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runner}/bin/ansible-runner";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'mkdir -p \"$(dirname \"${cfg.markerPath}\")\" && touch \"${cfg.markerPath}\"'";
      };
      Install = lib.optionalAttrs cfg.runOnBoot {
        WantedBy = [ "default.target" ];
      };
    } cfg.extraSystemdConfig;

    home.activation.ansible-check = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-failed --quiet ansible.service 2>/dev/null; then
          echo "services.ansible: user ansible.service is in the 'failed' state." >&2
          echo "  Inspect with: journalctl --user -u ansible -e" >&2
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
