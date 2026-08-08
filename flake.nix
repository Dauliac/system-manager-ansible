{
  description = "Nix-native ansible bootstrap library — declare ansnix = { … }; get one systemd unit that runs a composed playbook against localhost.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        lib = import ./lib { inherit (nixpkgs) lib; };

        # System-context module — used by both NixOS and system-manager.
        # nixosModules.default === systemManagerModules.default per D8.
        nixosModules.default = import ./modules/system.nix {
          libExt = self.lib;
          rolesDir = ./roles;
        };
        systemManagerModules.default = self.nixosModules.default;

        # User-context module — home-manager.
        homeManagerModules.default = import ./modules/home-manager.nix {
          libExt = self.lib;
          rolesDir = ./roles;
        };

        # Discoverable role directory paths for consumers who want to import
        # a role's default without going through the module system.
        roles = import ./roles/discovery.nix { rolesDir = ./roles; };
      };

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        let
          libExt = self.lib;
          rolesDir = ./roles;
          checkLib = import ./checks/lib.nix { inherit pkgs libExt rolesDir; };
        in
        {
          # Aggregated flake-check gate — see build-validation capability.
          checks = checkLib.allChecks // {
            # Alias so `nix flake check` runs everything.
            default = checkLib.aggregate;
          };

          # Per-role lint runners for local dev.
          packages = checkLib.perRoleLintPackages;

          # Dev shell with the pinned toolchain — for hand-running roles.
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.ansible
              pkgs.ansible-lint
              pkgs.yamllint
              pkgs.python3
            ];
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
