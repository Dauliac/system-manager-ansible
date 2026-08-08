## Purpose

Defines the outward-facing `ansnix` module — a real NixOS-style service, exposed identically from `nixosModules.default` / `systemManagerModules.default` (system context) and mirrored under `homeManagerModules.default` (user context). Each module invocation produces one composed playbook and one systemd unit, and the post-deploy hook propagates a failed unit up through `switch` so the deployer sees the failure instead of a silent success.

## ADDED Requirements

### Requirement: `nixosModules.default` and `systemManagerModules.default` are the same module

The flake SHALL export `nixosModules.default` and `systemManagerModules.default` pointing to the same file. The exposed option tree SHALL live under the option path `ansnix`.

#### Scenario: Both flake outputs reference the same module file
- **WHEN** a consumer imports `inputs.ansnix.nixosModules.default` and another consumer imports `inputs.ansnix.systemManagerModules.default`
- **THEN** both imports load the identical module file, and both declare the option path `ansnix.*` with the same submodule signature

### Requirement: `ansnix` exposes a real NixOS service option tree

The module SHALL declare `ansnix` with these top-level options:

- `enable` (`bool`, default `false`): standard NixOS enable toggle.
- `package` (`mkPackageOption pkgs "ansible" { }`): the ansible toolchain used at runtime.
- `roles` (`attrsOf submodule`, default `{ }`): role invocations, one per attribute name. See next requirement for the submodule shape.
- `vars` (`attrsOf anything`, default `{ }`): module-level extra vars rendered to a JSON file and passed via `--extra-vars @<file>`.
- `runOnBoot` (`bool`, default `true`): install `wantedBy = [ "multi-user.target" ]` on the generated unit.
- `runOnActivation` (`bool`, default `false`): if `true`, run the unit synchronously during activation and block on it.
- `markerPath` (`str`, default `/var/lib/ansnix/ansible.done`): systemd `ConditionPathExists=!` marker.
- `disableMarker` (`bool`, default `false`): if `true`, no marker check.
- `onFailure` (`enum ["fail-activation" "warn" "ignore"]`, default `"fail-activation"`): post-deploy hook behaviour.
- `extraSystemdConfig` (`attrsOf anything`, default `{ }`): merged verbatim into the generated `systemd.ansnix` attrset.

There SHALL NOT be a top-level `ansnix.tasks` option — inline tasks live under `ansnix.roles.<name>.tasks`. There SHALL NOT be a top-level `roleOrder` option — ordering is per-role via `priority` / `after` / `before` / `requires`.

#### Scenario: A minimal working host declaration
- **WHEN** a host sets:
  ```
  ansnix = {
    enable = true;
    roles.apt-packages.packages = [ "niri" ];
  };
  ```
- **THEN** the resulting system has a `systemd.ansnix` unit whose `ExecStart` runs a composed playbook `import_role`ing `apt-packages` with `packages = [ "niri" ]`

### Requirement: Every `ansnix.roles.<name>` submodule exposes the common fields plus disk-role schema

Each entry under `ansnix.roles` SHALL declare these common options, always available regardless of whether the role is disk-backed or inline:

- `enable` (`bool`, default `true`): inclusion toggle.
- `priority` (`int`, default `100`): coarse ordering hint (lower runs earlier).
- `tasks` (`listOf attrs`, default `[ ]`): inline task definitions.
- `handlers` (`listOf attrs`, default `[ ]`): inline handler definitions.
- `after` (`listOf str`, default `[ ]`): soft ordering deps (silently dropped if target absent).
- `before` (`listOf str`, default `[ ]`): soft ordering deps, reverse direction.
- `requires` (`listOf str`, default `[ ]`): hard deps; fail eval if target absent or disabled.
- `checkable` (`bool`, default `false`): whether the role participates in `--check` validation.

If `roles/<name>/` exists on disk, its `meta/nix-options.nix::options` SHALL additionally merge into the submodule under the same attribute path (`ansnix.roles.<name>.<option>`).

#### Scenario: Common fields on a disk role
- **WHEN** `roles/apt-packages/` exists and a caller writes `ansnix.roles.apt-packages = { packages = [ "niri" ]; priority = 100; after = [ "apt-repo" ]; };`
- **THEN** both the schema field (`packages`) and common fields (`priority`, `after`) are accepted without eval error

#### Scenario: Inline role with common fields
- **WHEN** a caller writes `ansnix.roles.tty-autologin = { priority = 200; tasks = [ ... ]; };` and no disk role of that name exists
- **THEN** the role is treated as inline and composed with priority 200

### Requirement: Every declared role must have a body

For every enabled entry under `ansnix.roles`, at least one of the following SHALL be true, otherwise Nix eval SHALL fail:

- A disk role directory exists at `roles/<name>/`, OR
- `.tasks` is non-empty.

The failure message SHALL identify the offending role name and both possible remediations.

#### Scenario: Empty entry is rejected
- **WHEN** a caller writes `ansnix.roles.foo = { };` and no `roles/foo/` disk directory exists
- **THEN** eval fails with `ansnix.roles.foo: neither a disk role at roles/foo/ nor inline tasks — nothing to run`

### Requirement: The module generates exactly one systemd unit

Regardless of how many roles are declared under `ansnix.roles`, the module SHALL create exactly one systemd unit — `systemd.ansnix` (system) or `systemd.user.ansnix` (home-manager) — whose `ExecStart` runs the composed playbook.

#### Scenario: Many roles, one unit
- **WHEN** a host declares five roles under `ansnix.roles`
- **THEN** exactly one systemd unit named `ansnix.service` exists, and `systemctl list-units 'ansible*'` returns a single row

### Requirement: `homeManagerModules.default` mirrors the surface under the user session

The flake SHALL export `homeManagerModules.default` with the exact same `ansnix` option tree as the system module, except:

- Generated unit is `systemd.user.ansnix`.
- Composition passes `become = false` to `lib.composePlaybook`.
- Default `markerPath` is `$XDG_STATE_HOME/ansnix/ansible.done`.
- Post-deploy hook uses `systemctl --user is-failed ansnix.service`.

The module SHALL NOT reject any role at eval time based on its content; roles whose tasks require root will fail at runtime under home-manager, consistent with how ansible behaves.

#### Scenario: A user-safe role composes and runs
- **WHEN** a home-manager consumer declares roles whose tasks work without root
- **THEN** the user systemd unit is generated and starts under the user's session

#### Scenario: A root-requiring role fails at runtime, not at eval
- **WHEN** a home-manager consumer declares a role whose tasks use `apt`
- **THEN** Nix eval succeeds, activation succeeds, and the unit fails at runtime with ansible's own permission error visible in `journalctl --user -u ansnix`

### Requirement: Post-deploy hook propagates unit failures through `switch`

Both modules SHALL install an activation script that runs after the systemd unit is generated and (if `runOnActivation = true`) started. The script SHALL call `systemctl [--user] is-failed ansnix.service` and, if the unit is in the `failed` state:

1. Print the exact `journalctl [--user] -u ansible -e` command to inspect.
2. Behave according to `onFailure`:
   - `"fail-activation"`: exit non-zero (default).
   - `"warn"`: print a warning, exit zero.
   - `"ignore"`: skip the check entirely.

#### Scenario: Crashed unit fails `system-manager switch`
- **GIVEN** `ansnix.onFailure = "fail-activation"` and `ansnix.service` is in `failed` state
- **WHEN** the deployer runs `system-manager switch`
- **THEN** the activation script exits non-zero, `switch` reports failure to the deployer's shell, and the printed message includes `journalctl -u ansnix -e`

#### Scenario: `warn` mode does not fail switch
- **GIVEN** `ansnix.onFailure = "warn"` and `ansnix.service` is in `failed` state
- **WHEN** the deployer runs `system-manager switch`
- **THEN** the activation script prints a warning and exits zero, and `switch` completes successfully

#### Scenario: Home-manager mirror
- **GIVEN** the home-manager module and a failed user unit with `onFailure = "fail-activation"`
- **WHEN** the deployer runs `home-manager switch`
- **THEN** the activation exits non-zero, and the printed inspection command uses `journalctl --user -u ansnix`

### Requirement: Module option merging supports distributed role authoring

The `ansnix.roles.<name>` submodule's `listOf` options (`tasks`, `handlers`, `after`, `before`, `requires`, plus any `listOf` from disk-role schemas) SHALL merge (concatenate) when defined from multiple modules. `attrsOf` options SHALL merge per key. Scalar options follow standard NixOS module-merge rules (last write with a warning on conflict).

#### Scenario: List options merge across files
- **GIVEN** `modules/a.nix` sets `ansnix.roles.apt-packages.packages = [ "niri" ];` and `modules/b.nix` sets `ansnix.roles.apt-packages.packages = [ "docker.io" ];`
- **WHEN** both modules are imported into the same host
- **THEN** the composed role invocation has `packages = [ "niri" "docker.io" ]` (order determined by module merge semantics)

### Requirement: The module surface is stable and versioned via the flake

Consumers importing `inputs.ansnix.systemManagerModules.default` SHALL rely on the `ansnix` option tree defined above. Breaking option renames or removals SHALL be gated by a new OpenSpec change with a `Modified Capabilities` entry against `nix-module-api`, and SHALL bump a `version` attribute exposed at `lib.moduleApiVersion`.

#### Scenario: Reading the current module API version
- **WHEN** a consumer evaluates `inputs.ansnix.lib.moduleApiVersion`
- **THEN** it returns an integer that increments only when this capability's requirements change
