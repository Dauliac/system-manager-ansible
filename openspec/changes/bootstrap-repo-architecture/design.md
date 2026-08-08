## Context

The repo is empty (`.git/` only). The reference implementation is
`../dotfiles/modules/system-manager/debian/{default.nix,bootstrap.yml,README.md}`:
a Nix module ships a single hardcoded ansible playbook as a systemd oneshot, run
by `ansible-core` from `/nix/store`, gated by a `.done` marker under
`/var/lib/dotfiles/`. That module has no options, no validation, no failure
propagation, and no reuse story — it is the anti-pattern we are extracting from.

Constraints we accept up front:

- **Localhost-only.** No inventory management, no SSH, no become-over-SSH. `--connection=local --inventory=localhost,` is the *only* execution mode.
- **Nix is the authoring interface for playbook composition.** YAML playbooks are a *render target*, never hand-written by consumers. Disk roles remain hand-written YAML (that's where ansible tooling lives); inline roles are authored in Nix and get on-the-fly YAML generated at build time.
- **One `ansnix` module invocation = one playbook = one systemd unit** (see D1).
- **The module surface reads like a real NixOS service.** `enable`, `package`, `roles` (attrset). No invented terminology.
- **Both `become: yes` (system) and `become: no` (user) contexts are first-class.**

## Goals / Non-Goals

**Goals:**

- Make the role the reusable, testable, individually-linted unit — whether it lives on disk or is authored inline.
- Give the Nix consumer a small, typed API that reads like `services.nginx` — role attrs hoisted directly under `roles.<name>`, no separate `vars` bucket, no separate `tasks` list at the module level.
- Make composition **distributable**: any nix file can declare a role invocation or extend one, without central coordination.
- Fail the deploy loudly at build time for anything ansible can detect statically, and at activation time for anything runtime.
- Expose the *same* role library through two runtime harnesses (system and user).

**Non-Goals:**

- **Remote inventory / multi-host orchestration.** Use plain ansible.
- **Ansible-galaxy compatibility.** Roles follow the ansible role filesystem convention but are not published to galaxy.
- **Replacing what nix + system-manager can already do.** Roles exist only for what `dpkg` / PAM / apt-repo / user-in-group semantics require.
- **Runtime template rendering from Nix state.** Vars are baked into the playbook at eval time.
- **Eval-time enforcement of user-vs-system role compatibility.** Runtime failure is honest.
- **Ansible-native `meta/main.yml::dependencies`.** We own composition; deps are declared in Nix at the call site (see D11). Roles MAY carry `meta/main.yml::dependencies` for standalone-ansible use, but the composer ignores it.

## Decisions

### D1. One `ansnix` invocation = one playbook = one systemd unit

**Decision.** All declared roles compose into a single rendered playbook, run by a single systemd unit named `ansnix.service` (system) or `ansnix.service` under `--user` (home-manager).

**Why.**

- **Bootstrap workloads don't benefit from multi-unit split.** Task-level batching (`apt: name: [a,b,c]` is one apt call) provides the parallelism that matters. Multi-unit orchestration would only serialize via `After=` anyway.
- **One unit is easier to reason about.** One journal, one status, one marker, one activation check.
- **`systemctl status ansible` / `journalctl -u ansnix` reads like any other service.**

**Alternatives considered.**

- *`playbooks.<name>` attrset (early design).* Rejected: layer of naming the caller doesn't want; isolation benefit illusory at bootstrap scale.
- *Opt-in per-role `async` for real concurrency.* Deferred — not needed at current scale.

### D2. Unified `ansnix.roles.<name>` namespace — disk, inline, or hybrid

**Decision.** `ansnix.roles.<name>` is a submodule with:

- **Common fields on every role invocation:**
  - `enable` (`bool`, default `true`) — opt-out toggle.
  - `priority` (`int`, default `100`) — coarse ordering hint (lower runs earlier).
  - `tasks` (`listOf attrs`, default `[ ]`) — inline task definitions.
  - `handlers` (`listOf attrs`, default `[ ]`) — inline handler definitions.
  - `after` / `before` / `requires` — dependency edges (see D11).
- **Role-specific fields:** if a disk role `roles/<name>/` exists, its `meta/nix-options.nix::options` are merged into the submodule so caller can write `ansnix.roles.apt-repo.repos = [...]`.

**Composer resolution per entry:**

1. **Disk-backed** (`roles/<name>/` exists, `.tasks` empty) — invoke the disk role with the caller's schema attrs as inline `vars:`.
2. **Inline-only** (no disk role, `.tasks` non-empty) — generate `/nix/store/<hash>-inline-<name>/tasks/main.yml` from `.tasks`; treat as a role.
3. **Hybrid** (disk role exists, `.tasks` also non-empty) — invoke the disk role, then append the inline tasks as extra tasks within the same invocation (or emit them as a second task-block right after).
4. **Neither** (no disk role, `.tasks` empty) — assertion failure at eval with a clear message. `ansnix.roles.<name> = { };` with nothing to run is meaningless.

**Why.** Consumers get one namespace for both "reusable, typed, versioned" (disk roles) and "one-off, right-sized" (inline roles). The nix-module extension pattern applies uniformly.

**Alternatives considered.**

- *Separate `ansnix.roles` (disk) and `ansnix.inlineRoles` (inline).* Cleaner semantic split but bureaucratic. Two ways to do the same thing.
- *Only disk roles.* Rejected: forces a directory for every 3-task feature; too heavy.
- *Only inline roles.* Rejected: loses `ansible-lint` fidelity on source, loses reuse across hosts.

### D3. Per-role attrs hoisted directly under `ansnix.roles.<name>`

**Decision.** No intermediate `vars` bucket. Callers write:

```nix
ansnix.roles.apt-repo.repos    = [ ... ];
ansnix.roles.apt-packages.packages = [ "niri" ];
```

Not `ansnix.vars.apt-repo.repos = [...]`.

**Why.** Matches every stock NixOS service (`services.nginx.virtualHosts.<name>`, `services.postgresql.settings.<name>`). Also makes distributed extension trivial — any nix file can extend `roles.<name>.<opt>` and lists merge (concat) via module semantics.

### D4. Ordering is distributable — priority + `after`/`before`/`requires`, no central manifest

**Decision.** Every role invocation carries its own ordering constraints. The composer builds a DAG and topologically sorts:

- `after = [ name₁, name₂, ... ]` — soft ordering. This role runs after the listed roles **if they're in the composition**. Edge is silently dropped if a name is absent. No activation.
- `before = [ name₁, ... ]` — same, opposite direction.
- `requires = [ name₁, ... ]` — hard dep. Eval fails if any named role isn't declared. Implies `after`.
- `priority` (`int`, default `100`) — tie-breaker within the topological order. Lower runs earlier.

**Algorithm:**

1. Collect all declared roles with `.enable = true`.
2. Validate `requires`: for each role X and each `x ∈ X.requires`, assert `x` is in the set.
3. Build DAG from `after` / `before` / `requires` edges (drop `after`/`before` edges to absent roles).
4. Topological sort with `priority` (then name) as the deterministic tie-breaker.
5. Cycle detection: fail eval with the printed cycle path.

**Why.** No single file owns "the order". A new nix file can declare `ansnix.roles.foo = { priority = 75; after = [ "apt-repo" ]; ... };` without editing anyone else's config. Mirrors systemd's `Before=`/`After=`/`Requires=`.

**Alternatives considered.**

- *Top-level `roleOrder = [ ... ]` list.* Rejected: requires central coordination; adding a role means editing the manifest.
- *Priority only.* Rejected: can't express "must be after X if X present" without X's priority becoming public.
- *`requires` auto-activates missing roles with defaults.* Rejected: too much magic; explicit is clearer.

### D5. Per-role vars are rendered inline in the `roles:` block

**Decision.** The composed playbook renders per-role vars inline in each `import_role` task:

```yaml
tasks:
  - import_role: { name: apt-repo }
    vars:
      repos: [ ... ]
  - import_role: { name: apt-packages }
    vars:
      packages: [ ... ]
```

**No `--extra-vars @<json>` for per-role vars.** Ansible's variable precedence puts `roles: - role: X vars: {...}` above defaults but below `--extra-vars`, so any global overrides via `--extra-vars` still work if we need them later.

**Why.** Role authors write `{{ repos }}` naturally in `tasks/main.yml` — no namespaced references, no invented convention. Playbook YAML remains deterministic (same inputs → same file). One file per invocation is all we render.

**Alternatives considered.**

- *`--extra-vars @/nix/store/<hash>-vars.json` with per-role namespacing* (`{ "apt-repo": { "repos": [...] } }`). Rejected: forces role authors to write `{{ apt_repo.repos }}` (or worse with hyphens) — leaks the composition model into every role's tasks.
- *`vars_files:` per role.* Rejected: proliferates store paths and adds an implicit file-load ordering concern.

**Global vars escape hatch.** `ansnix.vars = { <key> = <value>; ... };` (attrset) still writes an `--extra-vars @<json>` for module-level vars that apply across all roles. Small, opt-in, non-conflicting.

### D6. Build-time validation is a Nix derivation; `--check` is opt-in per role

**Decision.** For each disk role, each generated-inline role, and the composed playbook, a check derivation runs in the nix sandbox:

1. `yamllint -c ${checks/config/yamllint.yml} <role-or-playbook>`
2. `ansible-lint --offline --profile production <role-or-playbook>` with `ANSIBLE_ROLES_PATH=${self}/roles:${genRoles}`
3. `ansible-playbook --syntax-check --inventory=localhost, <playbookFile>` (composed playbook only)
4. `ansible-playbook --check --diff --connection=local --inventory=localhost, <playbookFile>` — only if every role in the composition declares `checkable = true` (disk roles) or has `.checkable = true` on the module submodule (inline roles).

All four aggregate under `checks.<system>.default`, gated by `nix flake check`.

**Why.** Cached, hermetic, composes with `flake check`. `--check` is opt-in because `apt`, `lineinfile` on `/etc/pam.d/*`, etc. need root; the nix builder runs unprivileged.

### D7. Post-deploy hook = activation-time systemctl introspection

**Decision.** Both modules install an activation script that runs after the systemd unit is (re)generated and (if `runOnActivation = true`) started synchronously. The script calls `systemctl [--user] is-failed ansnix.service`; behaviour driven by `onFailure = "fail-activation" | "warn" | "ignore"`.

**Why.** `system-manager switch` and `home-manager switch` propagate the exit code of their activation scripts.

### D8. Two harnesses, one shared core; the module IS a real NixOS service

**Decision.** `lib/` holds pure composition logic. Two thin adapters:

```
modules/system.nix        # nixosModules.default === systemManagerModules.default
modules/home-manager.nix  # homeManagerModules.default
```

Both expose the exact same option tree under `ansnix`. They differ only in systemd namespace (`systemd.ansnix` vs `systemd.user.ansnix`), the `become` flag passed to composition, the default marker path, and which systemctl invocation the activation script uses.

The `nixosModules.default` and `systemManagerModules.default` flake outputs point to the **same file** — they are literally aliases.

### D9. Ansible toolchain is caller-configurable via `ansnix.package`

**Decision.** `package = lib.mkPackageOption pkgs "ansible" { }`. The runner uses `${cfg.package}/bin/ansible-playbook`; `PATH` carries `pkgs.python3`, `pkgs.gnupg`, `pkgs.gnutar`, `pkgs.gzip`, `pkgs.coreutils`, plus `/usr/sbin:/usr/bin:/sbin:/bin` for host tools.

**Why.** Standard NixOS pattern (`services.nginx.package`, `services.postgresql.package`). One-line override to swap `pkgs.ansible-core` or a locally pinned build.

### D10. Marker files are per-module-invocation and configurable

**Decision.** Default `/var/lib/ansnix/ansible.done` (system) or `$XDG_STATE_HOME/ansnix/ansible.done` (user). Overridable via `ansnix.markerPath`. `disableMarker = true` forces re-run on every trigger.

### D11. Role deps mirror systemd — `after`, `before`, `requires`

**Decision.** As covered in D4. Three edge types:

| Field | Semantics | Failure mode when target absent |
|---|---|---|
| `after` / `before` | Ordering only | Silently dropped |
| `requires` | Ordering + presence | Eval fails |

Cycle detection: eval fails with the printed cycle path (`A → B → C → A`).

**No `wants` yet.** Deferred until a use case appears.

**Ansible-native `meta/main.yml::dependencies` is deliberately ignored** by the composer (see Non-Goals). Deps that matter are declared in Nix at the call site.

### D12. Inline roles generate role directories at nix build time

**Decision.** When `ansnix.roles.<name>.tasks` is non-empty and no `roles/<name>/` exists on disk, `lib.generateInlineRole` produces a derivation at `/nix/store/<hash>-inline-<name>/` with:

```
/nix/store/<hash>-inline-<name>/
├── tasks/main.yml       # rendered from .tasks
├── handlers/main.yml    # rendered from .handlers (if any)
└── meta/main.yml        # min_ansible_version, name
```

`ANSIBLE_ROLES_PATH` in every runner and check derivation includes both `${self}/roles` and the union of generated-inline role paths. Ansible sees inline roles as regular roles.

**Why.** Uniformity — the composer emits `import_role: { name: X }` for both disk and inline roles. Ansible-lint runs on the generated dir the same way it runs on disk roles. No special-casing downstream.

## Risks / Trade-offs

- **Ordering surprises without explicit deps.** If nothing declares `after`/`requires` and everything has the default priority, the topo sort falls back to alphabetical role names. Documented in `roles/README.md`.
- **Inline-role lint fidelity.** `ansible-lint` runs on the generated `/nix/store/…` path, not on the Nix source. Errors point at generated YAML. Cost is manageable for small inline roles; if they get complex the natural refactor is "promote to a disk role".
- **Nix eval cost.** Reading `meta/nix-options.nix` per declared role at eval time is O(declared roles). Currently ≤20 roles per host — irrelevant.
- **`--check` mode is not a full test.** Skips modules that don't support it. Sanity gate, not a test suite.
- **Home-manager without `become`.** Tasks needing root fail at runtime. Deliberately not enforced at eval.
- **Migration cost for `dotfiles`.** Existing debian bootstrap must be re-authored as roles before the inline module can be deleted. Follow-up change.
- **Handlers with cross-role notify.** A handler defined in role A but notified from role B needs `notify:` to resolve at ansible runtime — supported by ansible, but the composer doesn't validate cross-role handler names at build time. Documented as a known gap; add validation if it bites.
- **`extraSystemdConfig` escape hatch.** Deliberate. Every good module has one; better than trying to reify every systemd option upfront.
