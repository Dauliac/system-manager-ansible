{ lib, ... }:
{
  checkable = true;
  options = {
    target = lib.mkOption {
      type = lib.types.str;
      default = "multi-user";
      example = "graphical";
      description = "Name of the systemd target (without .target suffix).";
    };
  };
}
