{ lib, ... }:
{
  checkable = false;
  options = {
    keyringDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/apt/keyrings";
      description = "Where signed-by keys are stored.";
    };
    repos = lib.mkOption {
      description = "APT repositories to declare (idempotent).";
      default = [ ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "sources.list.d filename stem AND keyring filename stem.";
          };
          url = lib.mkOption {
            type = lib.types.str;
            description = "Base URL (no trailing slash).";
          };
          keyUrl = lib.mkOption {
            type = lib.types.str;
            description = "URL of Release.key / signing key.";
          };
          suite = lib.mkOption {
            type = lib.types.str;
            default = "/";
            description = "APT suite (or '/' for flat OBS repos).";
          };
          components = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "APT components (empty for flat repos).";
          };
        };
      });
    };
  };
}
