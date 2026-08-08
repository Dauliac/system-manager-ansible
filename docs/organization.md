# Organizing roles — three approaches

Ansible in this repo can be organized three ways. Pick based on scale and reuse needs.

## A. Intent-typed roles with inline tasks

Roles ARE the intent. All tasks for a feature live in one role.

```nix
services.ansible.roles.setup-niri = {
  priority = 100;
  tasks = [
    { name = "keyring dir"; "ansible.builtin.file" = { path = "/etc/apt/keyrings"; state = "directory"; }; }
    { name = "fetch key"; "ansible.builtin.get_url" = { url = "…"; dest = "…"; }; }
    { name = "add repo"; "ansible.builtin.apt_repository" = { repo = "…"; filename = "danklinux"; }; }
    { name = "install"; "ansible.builtin.apt" = { name = [ "niri" "xwayland-satellite" ]; state = "present"; }; }
  ];
};
```

- ✅ Reads like documentation
- ✅ `journalctl -u ansible` shows intent names
- ❌ Fragments apt calls (3 separate installs instead of one batch)
- ❌ No reuse across hosts

## B. Primitive-typed roles + intent-named files (recommended default)

Roles are resource types (`apt-repo`, `apt-packages`, `pam-line`). Intent lives in the file *path* — same pattern as nixpkgs (`nixos/modules/services/networking/network-manager.nix`).

```nix
# modules/features/niri.nix
{
  services.ansible.roles.apt-repo.repos = [{ name = "danklinux"; url = "…"; keyUrl = "…"; }];
  services.ansible.roles.apt-packages.packages = [ "niri" "xwayland-satellite" ];
  services.ansible.roles.apt-packages.after = [ "apt-repo" ];
}

# modules/features/network-manager.nix
{
  services.ansible.roles.apt-packages.packages = [ "network-manager" ];  # merges into list
}
```

- ✅ Batches apt calls
- ✅ Reusable roles across hosts
- ✅ Distributed extension via module merge
- ⚠️ `journalctl` shows primitive names, not intents (file tree provides intent visibility instead)

## C. Hybrid — Nix `mkEnableOption` feature modules

Highest abstraction. Callers write `features.niri.enable = true;` and a helper module explodes to primitive-role contributions.

```nix
# lib/features/niri.nix
{ config, lib, ... }: {
  options.ansibleFeatures.niri.enable = lib.mkEnableOption "niri";
  config = lib.mkIf config.ansibleFeatures.niri.enable {
    services.ansible.roles.apt-repo.repos = [ … ];
    services.ansible.roles.apt-packages.packages = [ "niri" "xwayland-satellite" ];
  };
}
```

- ✅ Caller experience unmatched (`ansibleFeatures.niri.enable = true;`)
- ⚠️ Two cognitive layers to reason about

## Recommendation

**Start with B.** Use A for one-off things that don't fit any primitive. Graduate to C only if the same feature is invoked across many hosts and copy-paste becomes annoying.
