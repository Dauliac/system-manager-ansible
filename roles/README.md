# Role authoring guide

This directory contains the canonical library of **disk-backed** Ansible roles consumed by `services.ansible`. Each subdirectory is one role.

## Disk-role layout

```
roles/<name>/
├── tasks/main.yml          # required — role tasks (hand-written YAML)
├── defaults/main.yml       # required — mirror of meta/nix-options.nix keys
├── meta/main.yml           # required — ansible metadata (min_ansible_version, platforms)
├── meta/nix-options.nix    # required — typed Nix schema (source of truth)
├── handlers/main.yml       # optional — handlers
├── templates/*.j2          # optional — jinja templates
├── files/                  # optional — static files
└── README.md               # required — one-page role docs
```

## `meta/nix-options.nix` shape

```nix
{ lib, ... }:
{
  checkable = false;   # true only if the role's tasks are safe under `ansible-playbook --check`
                       # in the nix sandbox (unprivileged, no host mutation).
  options = {
    myOption = lib.mkOption {
      type = lib.types.str;
      default = "sensible-default";
      description = "One-line description.";
    };
    # ... more options ...
  };
}
```

Task files reference the options as normal ansible vars: `{{ myOption }}`.

## Inline roles

You do NOT need to author a disk role to add tasks. If you have a small one-off, use inline authoring at the caller site:

```nix
services.ansible.roles.tty-autologin = {
  priority = 200;
  tasks = [
    { name = "install override dir";
      "ansible.builtin.file" = { path = "/etc/systemd/system/getty@tty1.service.d"; state = "directory"; }; }
    { name = "write autologin override";
      "ansible.builtin.copy" = { dest = "..."; content = "..."; }; }
  ];
};
```

The composer generates a role directory at `/nix/store/…-inline-tty-autologin/` at build time. Ansible-lint runs on it just like any disk role.

## Rule of thumb

- **Disk role** — when the role is reusable across hosts, has typed options, and benefits from `ansible-lint` on stable YAML files.
- **Inline role** — when the tasks are one-shot for this host, small (≤5 tasks), and duplicating them is worse than the ceremony of a disk directory.
- **Hybrid** — declare both. Disk role runs first; inline tasks append.

See `docs/organization.md` for the three organizational approaches (primitive+intent-files vs inline intent-roles vs hybrid feature modules) and the recommended default.
