{ lib, ... }:
{
  checkable = false;
  options = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Debian packages to install (idempotent).";
    };
    updateCache = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run apt update before installing.";
    };
  };
}
