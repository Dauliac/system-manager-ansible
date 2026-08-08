## Purpose

Defines the nix-build-time validation gate: every role (disk-backed and generated-inline) and every composed playbook is checked with the full ansible ecosystem (yamllint, ansible-lint, `--syntax-check`, and opt-in `--check` dry-run) so that lint and syntax failures fail `nix flake check` — never first boot.

## ADDED Requirements

### Requirement: Every disk role has a lint check derivation

For every directory under `roles/`, the flake SHALL expose a check derivation named `check-role-<name>` under `checks.<system>` that:

1. Runs `yamllint -c ${checks/config/yamllint.yml} roles/<name>`.
2. Runs `ansible-lint --offline --profile production roles/<name>` with `ANSIBLE_ROLES_PATH=${self}/roles`.
3. Fails the derivation if either tool exits non-zero.

The derivation SHALL be hermetic — no network access, no host-tool escape.

#### Scenario: A syntactically invalid task fails the check
- **WHEN** `roles/apt-repo/tasks/main.yml` contains malformed YAML
- **THEN** `nix build .#checks.x86_64-linux.check-role-apt-repo` fails, and the failure output cites the offending file and line

#### Scenario: `ansible-lint` violation fails the check
- **WHEN** a task uses `command: apt install foo` instead of the `apt` module
- **THEN** the check derivation fails with `ansible-lint` rule `command-instead-of-module`

### Requirement: Every generated-inline role has a lint check derivation

For every inline role produced by `lib.generateInlineRole` in the composed configuration, the flake SHALL expose a check derivation named `check-inline-role-<name>` under `checks.<system>` that runs the same `yamllint` + `ansible-lint` pipeline against the generated `/nix/store/<hash>-inline-<name>/` directory. `ANSIBLE_ROLES_PATH` SHALL include both `${self}/roles` and the generated-inline directory's parent.

Failures in a generated-inline role's check SHALL name the role and note that the source is inline Nix in the caller's config (so contributors know where to look — not in `roles/`).

#### Scenario: Malformed inline task fails the check
- **WHEN** a caller writes `services.ansible.roles.foo.tasks = [ { name = "bad"; "ansible.builtin.file" = "not-a-dict"; } ];`
- **THEN** the generated `check-inline-role-foo` derivation fails, and the failure message identifies the inline role source

### Requirement: Every composed playbook has a syntax-check derivation

For every playbook composed via `lib.composePlaybook`, the flake SHALL expose a check derivation named `check-playbook-<name>` under `checks.<system>` that runs `ansible-playbook --syntax-check --inventory=localhost, <playbookFile>` with `ANSIBLE_ROLES_PATH` set to the composition's `rolesPath` (including both disk and generated-inline roles), and fails on non-zero exit.

#### Scenario: Missing role in composition
- **WHEN** a composed playbook references a role name not present in `rolesPath`
- **THEN** `check-playbook-<name>` fails at syntax-check with ansible's own `role search paths` error

### Requirement: `--check` dry-run is opt-in per role

A composed playbook SHALL additionally run `ansible-playbook --check --diff --connection=local --inventory=localhost, <playbookFile>` in its check derivation ONLY IF **every** included role (disk or inline) is `checkable = true`. If any included role is not `checkable`, the `--check` step is skipped and only `--syntax-check` runs.

For disk roles, `checkable` is read from `meta/nix-options.nix::checkable`. For inline roles, `checkable` is read from `services.ansible.roles.<name>.checkable`.

#### Scenario: A playbook with one non-checkable role skips `--check`
- **WHEN** a playbook composes `roles/apt-packages` (`checkable = false`) and `roles/systemd-default-target` (`checkable = true`)
- **THEN** the check derivation runs `--syntax-check` but not `--check`, and completes without attempting to touch the sandbox host

#### Scenario: A fully checkable playbook runs `--check`
- **WHEN** every role in the composition is `checkable = true`
- **THEN** the check derivation runs `--check --diff` and fails if ansible reports any error

### Requirement: Aggregated default check gates `nix flake check`

`checks.<system>.default` SHALL depend on every `check-role-*`, `check-inline-role-*`, and `check-playbook-*` in the flake, so that `nix flake check` fails if any individual check fails.

#### Scenario: One broken role fails the whole flake check
- **WHEN** `check-role-pam-line` fails
- **THEN** `nix flake check` exits non-zero and prints the aggregated failing derivation names

### Requirement: Config files for lint tools live in-tree

`checks/config/yamllint.yml` and `checks/config/.ansible-lint` SHALL exist in the repo and SHALL be the sole configuration consulted by the check derivations. Contributors SHALL NOT override lint config per-role.

#### Scenario: A role tries to hide errors with a local `.ansible-lint`
- **WHEN** a contributor adds `roles/foo/.ansible-lint` with rule overrides
- **THEN** the check derivation ignores it (it invokes `ansible-lint -c ${checks/config/.ansible-lint}` explicitly)
