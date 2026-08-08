# systemd-default-target

Set the default systemd target by symlinking `/lib/systemd/system/<target>.target` to `/etc/systemd/system/default.target`.

**Root required.**

## Options

- `target` (str, default `"multi-user"`) — target name without the `.target` suffix. Common values: `multi-user`, `graphical`.

## Example

```nix
services.ansible.roles.systemd-default-target.target = "multi-user";
```
