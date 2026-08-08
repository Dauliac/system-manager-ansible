# ansnix

Nix-native Ansible bootstrap library for Debian / non-NixOS hosts managed via [system-manager](https://github.com/numtide/system-manager) or [home-manager](https://github.com/nix-community/home-manager).

**Declare `ansnix = { … };`, get one `ansnix.service` systemd unit that runs a composed playbook against localhost, and fail loud on activation if it crashes.**

## Quickstart

```nix
{
  inputs.ansnix.url = "github:Dauliac/ansnix";

  outputs = { self, nixpkgs, system-manager, ansnix, ... }: {
    systemConfigs.myhost = system-manager.lib.makeSystemConfig {
      modules = [
        ansnix.systemManagerModules.default
        ({ pkgs, ... }: {
          ansnix = {
            enable  = true;
            package = pkgs.ansible;

            roles = {
              apt-packages.packages = [ "network-manager" "niri" ];
              apt-repo.repos = [{
                name   = "danklinux";
                url    = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13";
                keyUrl = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13/Release.key";
              }];
              apt-packages.after = [ "apt-repo" ];
            };
          };
        })
      ];
    };
  };
}
```

## What this repo is

- **A library of disk-backed Ansible roles** under [`roles/`](./roles) — one directory per role, typed inputs in `meta/nix-options.nix`.
- **A Nix composition layer** under [`lib/`](./lib) that reads roles, resolves dependency ordering, generates on-the-fly role directories from inline Nix task lists, and renders a deterministic ansible playbook.
- **Two module APIs**:
  - `nixosModules.default` / `systemManagerModules.default` — system-wide, `become: yes`, `systemd.ansnix`.
  - `homeManagerModules.default` — user-scoped, `become: no`, `systemd.user.ansnix`.
- **A build-time validation gate** under [`checks/`](./checks) — `yamllint` + `ansible-lint` per role, wired into `nix flake check`.

## Design docs

- [`openspec/changes/bootstrap-repo-architecture/`](./openspec/changes/bootstrap-repo-architecture/) — the initial architecture proposal, design decisions, and per-capability specs.
- [`roles/README.md`](./roles/README.md) — role authoring guide.
- [`docs/organization.md`](./docs/organization.md) — how to organize roles for readability.

## Non-goals

- Remote inventory / multi-host orchestration. Use plain ansible for that.
- Replacing what nix + system-manager can already do. This exists only for what dpkg / PAM / apt-repo / user-in-group semantics require.
