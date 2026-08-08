# apt-repo

Declaratively manage `/etc/apt/keyrings/*.asc` + `/etc/apt/sources.list.d/*.list` entries.

**Root required.** Use only under `nixosModules.default` / `systemManagerModules.default`.

## Options

- `keyringDir` (str, default `/etc/apt/keyrings`) — where signed-by keys live.
- `repos` (list) — each entry:
  - `name` (str, required) — sources.list filename stem.
  - `url` (str, required) — base repo URL, no trailing slash.
  - `keyUrl` (str, required) — URL of the signing key (Release.key).
  - `suite` (str, default `/`) — APT suite, use `/` for flat OBS repos.
  - `components` (list of str, default `[]`) — APT components.

## Example

```nix
services.ansible.roles.apt-repo.repos = [{
  name   = "danklinux";
  url    = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13";
  keyUrl = "https://download.opensuse.org/repositories/home:AvengeMedia:danklinux/Debian_13/Release.key";
}];
```
