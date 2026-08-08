## Purpose

Defines the two authoring shapes for a role — a **disk-backed** role living under `roles/<name>/` with a typed Nix schema, or an **inline** role declared entirely in Nix via `ansnix.roles.<name>.tasks` — plus the shared metadata rules that make both consumable by the same composition layer.

## ADDED Requirements

### Requirement: Disk-backed roles live one-per-directory under `roles/`

Every disk-backed role SHALL live under `roles/<name>/` at the repo root. `<name>` SHALL be kebab-case and match the directory name exactly. No role SHALL span multiple directories, and no directory under `roles/` SHALL contain anything other than a single role.

#### Scenario: A well-formed disk role
- **WHEN** a contributor creates `roles/apt-repo/` with `tasks/main.yml`, `defaults/main.yml`, `meta/main.yml`, `meta/nix-options.nix`, and `README.md`
- **THEN** `lib.readRole ./roles/apt-repo` returns a role attrset without error

#### Scenario: A malformed disk role
- **WHEN** `roles/broken/` is missing `meta/nix-options.nix`
- **THEN** `lib.readRole` raises a Nix eval error identifying the missing file by absolute path

### Requirement: `meta/nix-options.nix` is the source of truth for disk-role inputs

Every disk role SHALL ship a `meta/nix-options.nix` that evaluates to an attrset of the shape `{ options, config ? { }, checkable ? false }`.

- `options` SHALL be authored using `lib.mkOption` with types drawn from `lib.types`.
- `checkable` (default `false`) SHALL indicate whether the role's tasks are safe to run under `ansible-playbook --check` inside the nix build sandbox.
- The role's `defaults/main.yml` SHALL mirror the same top-level keys as `options` so the role remains runnable from a plain ansible invocation.
- The role SHALL NOT declare any `context` field or equivalent runtime-target metadata. Where the role runs (system vs user) is determined by which module imports it.

#### Scenario: Typed attrs are validated at eval time
- **WHEN** a caller writes `ansnix.roles.apt-repo.repos = "not-a-list"` and the disk role's schema declares `repos` as `listOf submodule`
- **THEN** Nix eval fails with a type error citing the role name and the option path

### Requirement: Inline roles are authored via `ansnix.roles.<name>.tasks`

An inline role SHALL exist whenever a caller sets `ansnix.roles.<name>.tasks` to a non-empty list AND no `roles/<name>/` exists on disk. Inline roles:

- SHALL declare their tasks as a list of Nix attrsets that render 1:1 to ansible task YAML.
- MAY declare `handlers` as a list of ansible handler attrsets.
- MAY declare `checkable` (`bool`, default `false`) directly on the module submodule.
- SHALL be given a generated role directory at `/nix/store/<hash>-inline-<name>/` by `lib.generateInlineRole` at nix-build time, containing `tasks/main.yml`, `handlers/main.yml` (if any), and `meta/main.yml`.

#### Scenario: A caller declares an inline role
- **WHEN** a caller writes `ansnix.roles.tty-autologin = { tasks = [ { name = "..."; "ansible.builtin.copy" = { ... }; } ]; };` and no `roles/tty-autologin/` directory exists
- **THEN** the composition step generates `/nix/store/<hash>-inline-tty-autologin/tasks/main.yml` and the playbook `import_role`s it by name

#### Scenario: An empty entry is rejected
- **WHEN** a caller writes `ansnix.roles.foo = { };` and no `roles/foo/` disk directory exists
- **THEN** Nix eval fails with `ansnix.roles.foo: neither a disk role at roles/foo/ nor inline tasks — nothing to run`

### Requirement: Hybrid roles combine disk tasks with inline extras

If `roles/<name>/` exists on disk AND `ansnix.roles.<name>.tasks` is non-empty, the composer SHALL treat the entry as hybrid: the disk role runs first, then the inline tasks execute in the same invocation (as a task block that follows the disk role's `import_role`). Inline `handlers` on a hybrid entry SHALL be additive to the disk role's handlers.

#### Scenario: Hybrid role composes both
- **WHEN** `roles/apt-repo/` exists and a caller writes `ansnix.roles.apt-repo = { repos = [ ... ]; tasks = [ { name = "extra fixup"; ... } ]; };`
- **THEN** the rendered playbook `import_role`s `apt-repo` first, then runs the inline `extra fixup` task

### Requirement: Every role invocation carries the same common fields

Regardless of whether a role is disk-backed, inline, or hybrid, `ansnix.roles.<name>` SHALL expose these common fields:

- `enable` (`bool`, default `true`) — inclusion toggle.
- `priority` (`int`, default `100`) — coarse ordering.
- `tasks` / `handlers` — inline additions (empty by default).
- `after` / `before` / `requires` — dependency edges.
- `checkable` (`bool`, default `false`) — participation in `--check` validation.

If a disk role of the same name exists, its `meta/nix-options.nix::options` SHALL be additionally merged into the submodule.

#### Scenario: Common fields available on an inline-only role
- **WHEN** a caller declares an inline role with `priority = 200; after = [ "apt-repo" ];`
- **THEN** the composer places it after `apt-repo` in the topological sort and later than any priority-100 role that isn't otherwise constrained

### Requirement: Ansible-native `meta/main.yml::dependencies` is not consumed by the composer

A disk role MAY declare `dependencies` in its `meta/main.yml` for standalone ansible use (running the role outside our composition layer). The composer SHALL ignore that field entirely. All dependency information consumed by the composer SHALL come from `ansnix.roles.<name>.{after,before,requires}` at the call site.

#### Scenario: Disk role dependency ignored by composer
- **GIVEN** `roles/foo/meta/main.yml` declares `dependencies: [{ role: bar }]` and `bar` is NOT declared under `ansnix.roles`
- **WHEN** the composer runs
- **THEN** `bar` is NOT automatically added to the composition, and no assertion fires (composer never inspected `meta/main.yml::dependencies`)

### Requirement: Role tasks target `localhost` only

Task files under any role (disk `tasks/main.yml` or inline `.tasks`) SHALL NOT specify `delegate_to`, `remote_user`, `ansible_connection`, or any host-targeting directive. The composition layer guarantees `--connection=local --inventory=localhost,` at runtime.

#### Scenario: Lint rejects delegated tasks
- **WHEN** a role contains a task with `delegate_to: some-host`
- **THEN** `checks.<system>.check-role-<name>` fails, citing the offending file and line

### Requirement: Every disk role ships a README

`roles/<name>/README.md` SHALL exist and SHALL document, at minimum: the role's purpose in one sentence, whether the role's tasks require root (advisory only — not enforced by schema), and the exhaustive list of options with types and descriptions.

Inline roles do NOT require a README (they live inline in the caller's Nix source, which is self-documenting for the caller's use).

#### Scenario: Missing README on a disk role fails build
- **WHEN** `roles/foo/README.md` is absent
- **THEN** `nix flake check` fails at the role-check derivation for `foo`
