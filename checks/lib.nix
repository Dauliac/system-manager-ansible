{ pkgs, libExt, rolesDir }:
let
  lib = pkgs.lib;
  yamllintConfig = ../checks/config/yamllint.yml;
  ansibleLintConfig = ../checks/config/ansible-lint.yml;

  mkRoleCheck = { name, path }:
    pkgs.runCommandLocal "check-role-${name}" {
      nativeBuildInputs = [ pkgs.yamllint pkgs.ansible-lint pkgs.ansible ];
    } ''
      set -e
      # ansible / ansible-lint expect a writable HOME
      export HOME=$(mktemp -d)
      export ANSIBLE_LOCAL_TEMP=$HOME/.ansible/tmp
      export ANSIBLE_REMOTE_TEMP=$HOME/.ansible/tmp
      # Copy role into a writable dir since some ansible-lint rules want to write metadata
      cp -r ${path} $HOME/role
      chmod -R +w $HOME/role
      cd $HOME/role
      echo "── yamllint"
      yamllint -c ${yamllintConfig} .
      echo "── ansible-lint"
      export ANSIBLE_ROLES_PATH="${rolesDir}"
      ansible-lint --offline -c ${ansibleLintConfig} . || {
        echo "ansible-lint failed for role ${name}"
        exit 1
      }
      mkdir $out && touch $out/OK
    '';

  diskRoles = libExt.discoverRoles rolesDir;
  perRoleChecks = lib.mapAttrs' (n: r: {
    name = "role-${n}";
    value = mkRoleCheck { name = n; path = r.path; };
  }) diskRoles;

  perRoleLintPackages = lib.mapAttrs' (n: r: {
    name = "${n}-lint";
    value = pkgs.writeShellApplication {
      name = "${n}-lint";
      runtimeInputs = [ pkgs.yamllint pkgs.ansible-lint pkgs.ansible ];
      text = ''
        export ANSIBLE_ROLES_PATH="${rolesDir}"
        yamllint -c ${yamllintConfig} ${r.path}
        ansible-lint --offline -c ${ansibleLintConfig} ${r.path}
      '';
    };
  }) diskRoles;

  aggregate = pkgs.symlinkJoin {
    name = "ansnix-checks";
    paths = builtins.attrValues perRoleChecks;
  };
in
{
  allChecks = perRoleChecks;
  inherit perRoleLintPackages aggregate;
}
