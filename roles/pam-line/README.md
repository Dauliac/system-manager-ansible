# pam-line

Idempotently ensure a line is present in a PAM file (`/etc/pam.d/*`).

**Root required.** Assumes the target PAM file exists (typically owned by libpam0g).

## Options

- `lines` (list) — each entry:
  - `file` (str, required) — absolute PAM file path.
  - `line` (str, required) — exact line to insert if absent.

## Example

```nix
services.ansible.roles.pam-line.lines = [
  { file = "/etc/pam.d/common-auth";    line = "auth      optional     pam_gnome_keyring.so"; }
  { file = "/etc/pam.d/common-session"; line = "session   optional     pam_gnome_keyring.so auto_start"; }
];
```
