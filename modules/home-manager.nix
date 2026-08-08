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
        name = "ansnix";
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
          if systemctl --user is-failed --quiet ansnix.service; then
            echo "ansnix: user ansnix.service is in the 'failed' state." >&2
            echo "  Inspect with: journalctl --user -u ansnix -e" >&2
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
    enable = lib.mkEnableOption "ansnix (user-context)";
    package = lib.mkPackageOption pkgs "ansible" { };
    roles = lib.mkOption { type = lib.types.attrsOf roleSubmodule; default = { }; };
    vars = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
    runOnBoot = lib.mkOption { type = lib.types.bool; default = true; };
    runOnActivation = lib.mkOption { type = lib.types.bool; default = false; };
    markerPath = lib.mkOption {
      type = lib.types.str;
      default = "%S/ansnix/done";
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
    systemd.user.services.ansnix = lib.recursiveUpdate {
      Unit = {
        Description = "ansnix: composed ansible playbook (user, localhost)";
      } // lib.optionalAttrs (!cfg.disableMarker) {
        ConditionPathExists = "!${cfg.markerPath}";
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runner}/bin/ansnix-runner";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'mkdir -p \"$(dirname \"${cfg.markerPath}\")\" && touch \"${cfg.markerPath}\"'";
      };
      Install = lib.optionalAttrs cfg.runOnBoot {
        WantedBy = [ "default.target" ];
      };
    } cfg.extraSystemdConfig;

    systemd.user.services.ansnix-check = lib.mkIf (cfg.onFailure != "ignore") {
      Unit = {
        Description = "ansnix: post-deploy failure check (user)";
        After = [ "ansnix.service" ];
        Wants = [ "ansnix.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${checkService}/bin/ansnix-check";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
