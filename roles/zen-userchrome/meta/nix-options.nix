{ lib, ... }:
{
  checkable = true;
  options = {
    zenDir = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the Zen browser flatpak's .zen directory (the one
        containing profiles.ini). No default — the caller must provide it,
        since it depends on the user's home directory and flatpak app id.
      '';
      example = "/home/alice/.var/app/app.zen_browser.zen/.zen";
    };

    profileArchives = lib.mkOption {
      description = ''
        Archives extracted into <default-profile>/chrome/. Idempotent via
        `creates:` — the archive is re-extracted only when its sentinel is
        missing.
      '';
      default = [ ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          src = lib.mkOption {
            type = lib.types.path;
            description = "Local (Nix store) path of the .zip archive.";
          };
          creates = lib.mkOption {
            type = lib.types.str;
            description = ''
              Sentinel file, relative to the profile's chrome/ dir. If it
              exists the archive is skipped.
            '';
          };
        };
      });
    };

    programArchives = lib.mkOption {
      description = ''
        Archives extracted into arbitrary absolute destinations (e.g. the
        flatpak's program dir under files/zen). Idempotent via `creates:`.
      '';
      default = [ ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          src = lib.mkOption {
            type = lib.types.path;
            description = "Local (Nix store) path of the .zip archive.";
          };
          dest = lib.mkOption {
            type = lib.types.str;
            description = "Absolute destination directory.";
          };
          creates = lib.mkOption {
            type = lib.types.str;
            description = "Absolute sentinel path. Skipped if it exists.";
          };
        };
      });
    };
  };
}
