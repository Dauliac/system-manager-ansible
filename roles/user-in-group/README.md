# user-in-group

Add users to supplementary groups (append-only, idempotent). User and groups must already exist.

**Root required.**

## Example

```nix
services.ansible.roles.user-in-group.memberships = [
  { user = "juliendauliac"; groups = [ "docker" ]; }
];
```
