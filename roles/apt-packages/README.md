# apt-packages

Install Debian packages via `ansible.builtin.apt`. One batched call = one apt lock acquisition.

**Root required.**

## Options

- `packages` (list of str) — packages to install.
- `updateCache` (bool, default `false`) — run `apt update` first.

## Example

```nix
services.ansible.roles.apt-packages = {
  packages = [ "niri" "network-manager" "libpam-gnome-keyring" ];
  after    = [ "apt-repo" ];  # if a repo defines any of these packages
};
```
