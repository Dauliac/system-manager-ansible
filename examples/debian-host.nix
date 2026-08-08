# Example host declaration — mirrors the semantics of the pre-ansnix debian
# bootstrap. Import into a system-manager or NixOS host config:
#
#   { inputs, ... }: {
#     imports = [
#       inputs.ansnix.systemManagerModules.default
#       ./debian-host.nix
#     ];
#   }
{
  ansnix = {
    enable = true;

    roles = {
      systemd-default-target = {
        priority = 50;
        target = "multi-user";
      };

      apt-repo = {
        priority = 60;
        repos = [{
          name = "danklinux";
          url = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13";
          keyUrl = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13/Release.key";
        }];
      };

      apt-packages = {
        priority = 100;
        after = [ "apt-repo" ];
        packages = [
          "network-manager"
          "niri"
          "xwayland-satellite"
          "libpam-gnome-keyring"
        ];
      };

      pam-line = {
        priority = 110;
        requires = [ "apt-packages" ];
        lines = [
          { file = "/etc/pam.d/common-auth";    line = "auth      optional     pam_gnome_keyring.so"; }
          { file = "/etc/pam.d/common-session"; line = "session   optional     pam_gnome_keyring.so auto_start"; }
        ];
      };

      user-in-group = {
        priority = 120;
        memberships = [
          { user = "juliendauliac"; groups = [ "docker" ]; }
        ];
      };
    };

    onFailure = "fail-activation";
  };
}
