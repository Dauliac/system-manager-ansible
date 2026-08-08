{ lib, ... }:
{
  checkable = false;
  options = {
    lines = lib.mkOption {
      description = "PAM lines to ensure present, one entry per (file, line).";
      default = [ ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          file = lib.mkOption {
            type = lib.types.str;
            description = "Absolute PAM file path (e.g. /etc/pam.d/common-auth).";
          };
          line = lib.mkOption {
            type = lib.types.str;
            description = "Exact line to ensure present.";
          };
        };
      });
    };
  };
}
