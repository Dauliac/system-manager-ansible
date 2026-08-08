## Why

`ansnix` extracts and generalizes the ad-hoc `bootstrap.yml`
that currently lives inline under `dotfiles/modules/system-manager/debian/`.
That playbook is a single monolith with hardcoded packages, users, PAM lines
and a repo URL; it can only be consumed one way (as a systemd oneshot triggered
by the Nix module that imports it) and has no build-time validation — a broken
task ships to first boot.

We want a Nix-native library repo whose surface is a **real NixOS service**:

- **One `ansnix` module** per host, matching the shape of `services.nginx`, `services.postgresql`, `services.k3s` — `enable`, `package`, and a small handful of typed options. No invented terminology; nothing that reads unlike a stock NixOS module.
- **One module invocation → one playbook → one systemd unit** (`ansnix.service`). Bootstrap-scale workloads (tens of tasks) run comfortably in a single ansible invocation. Task-level batching (`apt: name: [a,b,c]`) provides the parallelism that matters. Multiple systemd units would be strictly worse: harder to reason about, harder to fail-loud, and offers no meaningful concurrency on a single localhost.
- **One unified role namespace** — `ansnix.roles.<name>` accepts either a disk-backed role (`roles/<name>/` on disk, typed schema in `meta/nix-options.nix`) or an inline role authored directly in Nix (via `.tasks` / `.handlers` fields), or a hybrid of both. The composer resolves which at build time.
- **Definition and call in the same block.** Any nix file anywhere in the module system can write `ansnix.roles.<name> = { … };` and its tasks, vars and metadata merge in. Adding a feature = adding a nix file; removing a feature = deleting it. No central manifest.
- **Ordering is distributable.** Each role invocation declares its own `priority` (coarse) plus `after` / `before` / `requires` (fine-grained deps). The composer builds a DAG, topologically sorts, breaks ties by priority. No single file needs to know about all roles.
- **Nix composes the playbook.** Consumer never hand-writes YAML playbooks; they declare intent in Nix and get a rendered `.yml` at a deterministic `/nix/store` path. Per-role vars are rendered inline in the `roles:` block, so role authors write standard `{{ option_name }}` references — nothing invented, nothing namespaced.
- **Host is always `localhost`, connection `local`.** This repo is exclusively for host-side declarative bootstrap, not for pushing config to remote inventories.
- **Build-time validation.** `nix flake check` runs `ansible-lint`, `yamllint`, `ansible-playbook --syntax-check`, and (opt-in per role) `--check` dry-run against every role (disk and generated-inline) and the composed playbook. A broken task fails at `nix build`, not first boot.
- **Post-deploy failure hook.** After activation the module runs `systemctl is-failed` on the generated unit and propagates a non-zero exit up through `system-manager switch` / `home-manager switch`.
- **Two module APIs, one core.** `nixosModules.default` and `systemManagerModules.default` are the *same* module (system context, `systemd.ansnix`, `become: yes`). `homeManagerModules.default` mirrors the option tree exactly but wires `systemd.user.ansnix` and drops `become`. A role's context is decided by which module imports it, not by anything the role declares.

## What Changes

- Introduce the `roles/` directory as the canonical library of **disk-backed** roles. Each ships `tasks/main.yml`, `defaults/main.yml`, `meta/nix-options.nix`, `README.md`.
- Introduce a Nix API in `lib/` that:
  - reads a disk role and imports its `meta/nix-options.nix` schema (`lib.readRole`);
  - accepts inline roles (Nix task lists) and generates on-the-fly role directories at nix build time (`lib.generateInlineRole`);
  - composes an ordered set of role invocations + their attrs into one rendered playbook with inline `vars:` per role (`lib.composePlaybook`);
  - builds a runner derivation wrapping `ansible-playbook --connection=local --inventory=localhost,` using a **configurable** ansible package (`lib.mkPlaybookRunner`);
  - resolves ordering via a DAG built from `priority` + `after` / `before` / `requires` edges, with cycle detection.
- Introduce a **build-validation** derivation: per-role `yamllint` + `ansible-lint` (covering disk roles AND generated-inline roles), and per-composition `--syntax-check` + opt-in `--check`. Wired into `nix flake check`.
- Introduce a **NixOS / system-manager module** at `ansnix` exposing:
  - `enable` (`bool`), `package` (`mkPackageOption pkgs "ansible" { }`).
  - `roles` (`attrsOf submodule`) — each attribute is a role invocation. Common fields on every entry: `enable`, `priority`, `tasks`, `handlers`, `after`, `before`, `requires`. If a disk role of that name exists, its `meta/nix-options.nix` options merge in.
  - `runOnBoot` / `runOnActivation` / `markerPath` / `disableMarker` / `onFailure` / `extraSystemdConfig`.
  - Post-activation `systemctl is-failed` sweep, controlled by `onFailure = "fail-activation" | "warn" | "ignore"`.
- Introduce a **home-manager module** mirroring the exact same option tree, but generating `systemd.user.ansnix` and passing `become = false` to composition.
- Rewrite the current `dotfiles` debian bootstrap as roles (`apt-repo`, `apt-packages`, `pam-line`, `user-in-group`, `systemd-default-target`) — the worked example that validates the API against a real host.
- Document three organizational approaches for callers (primitive+intent-files, inline intent-roles, hybrid feature modules) so contributors don't reinvent the debate.

## Capabilities

### New Capabilities

- `role-authoring`: filesystem convention + `meta/nix-options.nix` schema contract for authoring disk-backed roles, plus the shape rules for inline Nix-authored roles. Roles are context-agnostic — where they run is decided by the importing module, not by the role.
- `playbook-composition`: Nix API for composing a `roles` attrset into a single rendered playbook (with inline `vars:` per role), including inline-role directory generation, dependency-graph resolution (`priority` + `after` / `before` / `requires`) with cycle detection, and the runner derivation that pins the configured ansible package.
- `build-validation`: nix-build-time validation of every declared role (disk-backed and generated-inline) and the composed playbook using the full ansible ecosystem (ansible-lint, yamllint, --syntax-check, opt-in --check dry-run).
- `nix-module-api`: the outward-facing `ansnix` option tree exposed by both `nixosModules.default` / `systemManagerModules.default` (identical) and `homeManagerModules.default` (user-context mirror), including the post-deploy hook that fails activation when the generated unit crashed.

### Modified Capabilities

_None — this is the initial change for an empty repo._

## Impact

- **New repo surface.** Consumers of `dotfiles` currently importing `inputs.self.modules.systemManager.debian` will migrate to `inputs.ansnix.systemManagerModules.default` and declare `ansnix = { enable = true; roles = { … }; };`. The old inline module can be deleted once migration lands.
- **Nix flake outputs added:** `lib`, `nixosModules.default`, `systemManagerModules.default` (aliased to `nixosModules.default`), `homeManagerModules.default`, `checks.<system>.*`, `packages.<system>.<role>-lint`.
- **Ansible toolchain is caller-configurable.** `ansnix.package` defaults to `pkgs.ansible` but can be overridden per host.
- **No external network at build time.** Validation runs `--syntax-check` and `--check` only; no `--connection=local` execution during nix build.
- **Failure surface changes.** Today a crashed task silently leaves the marker unset and re-runs on next boot. New behavior: the activation script exits non-zero, so `system-manager switch` / `home-manager switch` reports the failure to the deployer.
- **Roles are context-agnostic.** A role that internally uses `apt` will fail at runtime under home-manager because `apt` needs root — this is honest and doesn't need eval-time enforcement.
- **Ordering is composable.** No top-level `roleOrder` manifest — each role's `priority` and `after` / `before` / `requires` fields live at its declaration site, so ordering is distributable across many nix files without central coordination.
