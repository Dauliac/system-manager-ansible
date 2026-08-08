{ lib, ... }:
{
  checkable = false;
  options = {
    memberships = lib.mkOption {
      description = "Users to add to supplementary groups (idempotent, append-only).";
      default = [ ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          user = lib.mkOption {
            type = lib.types.str;
            description = "Username. Must already exist.";
          };
          groups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Supplementary groups to append.";
          };
        };
      });
    };
  };
}
