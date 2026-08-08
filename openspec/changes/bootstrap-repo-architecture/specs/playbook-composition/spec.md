## Purpose

Defines the Nix library API used by the `services.ansible` module to compose an attrset of role invocations (disk-backed, inline, or hybrid) into one rendered ansible playbook — resolving dependency ordering via a DAG, generating on-the-fly role directories for inline roles, rendering per-role vars inline in the `roles:`/`tasks:` block, and building the runner derivation that pins the caller-configured ansible package.

## ADDED Requirements

### Requirement: `lib.composePlaybook` produces exactly one rendered playbook per invocation

`lib.composePlaybook { name, package, roles, become ? true, extraVars ? { } }` SHALL return an attrset `{ playbookFile, extraVarsFile, orderedRoles, rolesPath }` where:

- `roles` is the attrset from `services.ansible.roles.*` after module merging.
- `playbookFile` is a `/nix/store` path to a `.yml` file declaring `hosts: localhost`, `connection: local`, `become: <become>`, `gather_facts: yes`, and a `tasks:` block with one `import_role` per composed entry.
- `extraVarsFile` is a `/nix/store` path to a JSON file with the module-level `extraVars` attrs, or `null` if `extraVars` is empty.
- `orderedRoles` is the ordered list of role names in the composed playbook, resolved via the DAG algorithm below.
- `rolesPath` is a colon-separated string of directory paths for `ANSIBLE_ROLES_PATH` — includes `${self}/roles` and the union of generated-inline-role paths.

#### Scenario: A single-role composition renders one YAML file
- **WHEN** `lib.composePlaybook { name = "ansible"; package = pkgs.ansible; roles = { apt-repo = { repos = [ ... ]; enable = true; priority = 100; ... }; }; }` is evaluated
- **THEN** `playbookFile` exists in the store, its `tasks:` block contains one `import_role: { name: apt-repo }` with inline `vars:`, and `orderedRoles = [ "apt-repo" ]`

### Requirement: Entries with `enable = false` are excluded from composition

`lib.composePlaybook` SHALL filter out entries where `.enable = false` before any dependency resolution, ordering, or rendering. Excluded entries SHALL NOT appear in `orderedRoles` and SHALL NOT contribute to `rolesPath`. `requires` edges pointing at a disabled role SHALL fail eval with a message identifying the disabled role.

#### Scenario: Disabling a role removes it
- **WHEN** `roles.apt-repo.enable = false` and no other role requires it
- **THEN** the composed playbook contains no `import_role: { name: apt-repo }` and `apt-repo` is absent from `orderedRoles`

#### Scenario: Requiring a disabled role fails eval
- **WHEN** `roles.pam-line.requires = [ "apt-packages" ]` and `roles.apt-packages.enable = false`
- **THEN** eval fails with `role 'pam-line' requires 'apt-packages' which is disabled`

### Requirement: Dependency resolution via `priority` + `after` / `before` / `requires`

`lib.composePlaybook` SHALL order composed entries by:

1. **Validate `requires`.** For each role X and each `x ∈ X.requires`, assert `x` is in the enabled-role set. Fail eval if not, with `role 'X' requires 'x' which is not declared`.
2. **Build DAG.** For each role X:
   - For each `x ∈ X.after` where `x` is in the set → add edge `x → X`.
   - For each `x ∈ X.before` where `x` is in the set → add edge `X → x`.
   - For each `x ∈ X.requires` → add edge `x → X` (unconditional; already validated).
   - Silently drop `after`/`before` edges whose target is absent.
3. **Topological sort** with (a) `priority` ascending, then (b) role name ascending as the deterministic tie-breaker.
4. **Detect cycles.** If the DAG is cyclic, fail eval with the printed cycle path (`role A → role B → role C → role A`).

#### Scenario: `requires` implies `after`
- **WHEN** `roles.pam-line.requires = [ "apt-packages" ]` and both roles are otherwise unconstrained
- **THEN** `orderedRoles` places `apt-packages` before `pam-line`

#### Scenario: Priority breaks ties within a topologically-valid layer
- **WHEN** two roles are independent (no edges) and one has `priority = 50` and the other `priority = 100`
- **THEN** the priority-50 role appears first in `orderedRoles`

#### Scenario: `after` edge to absent role is silently dropped
- **WHEN** `roles.apt-packages.after = [ "apt-repo" ]` but `apt-repo` is not declared
- **THEN** composition proceeds without failure; `apt-packages` orders solely by its own priority

#### Scenario: Cycle detection
- **WHEN** `roles.a.requires = [ "b" ]` and `roles.b.requires = [ "a" ]`
- **THEN** eval fails with `dependency cycle detected in services.ansible.roles: a → b → a`

### Requirement: Inline and hybrid roles produce generated role directories

For each enabled entry where `.tasks` is non-empty, `lib.composePlaybook` SHALL invoke `lib.generateInlineRole { name, tasks, handlers, checkable }` and add the resulting store path to `rolesPath`. The generated directory SHALL contain `tasks/main.yml`, `handlers/main.yml` (only if handlers were provided), and `meta/main.yml`.

For **hybrid** entries (both disk role and non-empty `.tasks`), the composer SHALL:

- Include the disk role directory in `rolesPath` via `${self}/roles`.
- Generate a companion directory `<hash>-inline-<name>-extras` containing only the inline extras.
- In the rendered playbook: emit `import_role: { name: <name> }` (the disk role), immediately followed by `import_role: { name: <name>-extras }` (the inline additions), or an equivalent inline task block.

#### Scenario: Pure inline role gets a generated directory
- **WHEN** `roles.tty-autologin` is declared inline (no disk role of that name)
- **THEN** a generated directory `/nix/store/<hash>-inline-tty-autologin/tasks/main.yml` exists in the store and `rolesPath` includes its parent

#### Scenario: Hybrid role emits both disk and inline sections
- **WHEN** `roles/apt-repo/` exists and a caller declares `roles.apt-repo.tasks = [ { ... } ]`
- **THEN** the playbook contains both `import_role: { name: apt-repo }` and the inline tasks in that order

### Requirement: Per-role vars render inline in the composed playbook

For each composed entry, `lib.composePlaybook` SHALL render the caller-supplied schema attrs (from disk-role `meta/nix-options.nix` or freeform attrs on inline roles) as an inline `vars:` block on that entry's `import_role` task. The composer SHALL NOT use `--extra-vars` for per-role vars.

#### Scenario: Vars are inline per role
- **WHEN** `roles.apt-repo.repos = [ { name = "danklinux"; ... } ]` is composed
- **THEN** the rendered playbook contains `- import_role: { name: apt-repo }\n  vars:\n    repos:\n      - name: danklinux ...`

#### Scenario: Two roles' vars do not collide
- **WHEN** two roles both expose an option named `packages` and are both composed
- **THEN** each role's `packages` appears only inside that role's `vars:` block; no top-level collision

### Requirement: `lib.mkPlaybookRunner` uses the caller-supplied ansible package

`lib.mkPlaybookRunner { package, playbookFile, extraVarsFile ? null, rolesPath }` SHALL return a derivation whose output is a shell script that invokes `${package}/bin/ansible-playbook --connection=local --inventory=localhost, --roles-path=${rolesPath} ${playbookFile}`, and appends `--extra-vars @${extraVarsFile}` when `extraVarsFile != null`. `PATH` SHALL be composed of `${package}`, `pkgs.python3`, `pkgs.gnupg`, `pkgs.gnutar`, `pkgs.gzip`, `pkgs.coreutils`, then `/usr/sbin:/usr/bin:/sbin:/bin` appended for host tools like `dpkg` and `apt`.

#### Scenario: Overriding the ansible package
- **WHEN** a caller sets `services.ansible.package = pkgs.ansible-core`
- **THEN** the generated runner's `ansible-playbook` resolves to `${pkgs.ansible-core}/bin/ansible-playbook`

### Requirement: Composed playbooks are deterministic

Two evaluations of `lib.composePlaybook` with identical inputs (including identical merge order at the module level) SHALL produce identical `playbookFile` paths (byte-identical outputs, same nix-store hash). Generated-inline-role directories SHALL be content-addressed so identical inline task lists yield the same store path across evaluations.

#### Scenario: Same inputs → same store paths
- **WHEN** `composePlaybook` is called twice with the same arguments
- **THEN** both invocations return the same `/nix/store/<hash>-*.yml` path
