## 1. Repo scaffolding

- [ ] 1.1 Add `flake.nix` with `nixpkgs`, `system-manager`, `home-manager`, `flake-parts` inputs; declare outputs stubs for `lib`, `nixosModules`, `systemManagerModules`, `homeManagerModules`, `checks`, `packages`.
- [ ] 1.2 Add `flake.parts` module layout under `modules/flake/` (mirroring the dendritic pattern used by `dotfiles`).
- [ ] 1.3 Add `.editorconfig`, `.gitignore`, `lefthook.yaml` (yamllint + nixfmt pre-commit), root `README.md` linking to `openspec/`.

## 2. Role authoring convention (`role-authoring` capability)

- [ ] 2.1 Document the `roles/<name>/` disk-role layout in `roles/README.md` — `defaults/main.yml`, `tasks/main.yml`, `meta/main.yml`, `meta/nix-options.nix`, `README.md` required; `handlers/`, `templates/`, `files/` optional.
- [ ] 2.2 Define the `meta/nix-options.nix` schema: `{ options, config ? { }, checkable ? bool }`. No `context` field.
- [ ] 2.3 Document the inline-role authoring shape (`services.ansible.roles.<name> = { tasks = [ … ]; handlers = [ … ]; };`) in the same `roles/README.md`.
- [ ] 2.4 Author `roles/apt-repo/` — deb/OBS repo declaration extracted from `bootstrap.yml`'s `danklinux-repo` block. `checkable = false`.
- [ ] 2.5 Author `roles/apt-packages/` — thin wrapper over `ansible.builtin.apt`. `checkable = false`.
- [ ] 2.6 Author `roles/pam-line/` — idempotent `lineinfile` on `/etc/pam.d/common-*`. `checkable = false`.
- [ ] 2.7 Author `roles/user-in-group/`. `checkable = false`.
- [ ] 2.8 Author `roles/systemd-default-target/`. `checkable = true` (the file-link module supports `--check`).

## 3. Nix composition library (`playbook-composition` capability)

- [ ] 3.1 Implement `lib.readRole` — reads a disk role directory, imports `meta/nix-options.nix`, returns `{ name, options, tasks-file, checkable }`.
- [ ] 3.2 Implement `lib.generateInlineRole { name, tasks, handlers ? [ ], checkable ? false }` — generates a `/nix/store/<hash>-inline-<name>/` role directory with `tasks/main.yml`, `handlers/main.yml`, `meta/main.yml`.
- [ ] 3.3 Implement `lib.composePlaybook { name, package, roles, become ? true, extraVars ? { } }`:
  - Filter entries where `.enable = true`.
  - For each entry, resolve disk vs inline vs hybrid (per D2).
  - Validate `requires` — fail eval when a required role isn't in the set.
  - Build DAG from `after` / `before` / `requires` edges (drop `after`/`before` to absent roles).
  - Topological sort with `priority` (then name) as tie-breaker.
  - Detect cycles; fail eval with the cycle path printed.
  - Render playbook YAML with `tasks:` block containing `import_role` per entry, inline `vars:` per role.
  - Render optional `--extra-vars @<json>` file from `extraVars`.
  - Return `{ playbookFile, extraVarsFile ? null, orderedRoles, rolesPath }`.
- [ ] 3.4 Implement `lib.mkPlaybookRunner { package, playbookFile, extraVarsFile ? null, rolesPath }` — produces the `writeShellApplication` runner. `ANSIBLE_ROLES_PATH` = `${rolesPath}`.
- [ ] 3.5 Unit-test `lib` composition in `checks.lib-tests` — pure-Nix assertions for: alphabetical fallback ordering, priority ordering, `after` edge drop when target absent, `requires` failure, cycle detection.

## 4. Build-time validation (`build-validation` capability)

- [ ] 4.1 Implement `lib.mkRoleCheck { role, rolesPath }` — derivation that runs `yamllint` + `ansible-lint --offline --profile production` on the role directory (disk OR generated-inline).
- [ ] 4.2 Implement `lib.mkPlaybookCheck { package, playbookFile, rolesPath, allCheckable }` — runs `--syntax-check`; if `allCheckable`, also `--check --diff`.
- [ ] 4.3 Pin `yamllint.yml` and `.ansible-lint` config files under `checks/config/`; documented as the project-wide standard.
- [ ] 4.4 Aggregate role and playbook checks (disk + generated-inline) into `checks.<system>.default`; wire into `nix flake check`.
- [ ] 4.5 Add `packages.<system>.<role>-lint` per disk role for local dev use.

## 5. System module — `nixosModules.default` / `systemManagerModules.default` (`nix-module-api` capability)

- [ ] 5.1 Implement `modules/system.nix` exposing the option tree at `services.ansible`:
  - `enable`, `package` (`mkPackageOption`), `runOnBoot`, `runOnActivation`, `markerPath`, `disableMarker`, `onFailure`, `extraSystemdConfig`, `vars` (module-level `extraVars`).
  - `roles` (`attrsOf submodule`): each submodule declares the common fields (`enable`, `priority`, `tasks`, `handlers`, `after`, `before`, `requires`, `checkable`) and — if a disk role of that name exists — dynamically merges in that role's `meta/nix-options.nix::options`.
- [ ] 5.2 Generate exactly one `systemd.services.ansible` unit — oneshot, `ConditionPathExists=!<marker>` when `disableMarker = false`, `After=network-online.target` when `runOnBoot`.
- [ ] 5.3 Emit `system.activationScripts.ansible-check` running the post-deploy `systemctl is-failed ansible.service` check with behavior driven by `onFailure`.
- [ ] 5.4 Assert at eval: for every declared role, at least one of `roles/<name>/` on disk OR `.tasks` non-empty must be true. Otherwise print `services.ansible.roles.<name>: neither a disk role at roles/<name>/ nor inline tasks — nothing to run`.
- [ ] 5.5 Export the module as both `nixosModules.default` and `systemManagerModules.default` (same file, aliased in `flake.nix`).

## 6. Home-manager module — `homeManagerModules.default` (`nix-module-api` capability)

- [ ] 6.1 Implement `modules/home-manager.nix` exposing the exact same `services.ansible` option tree.
- [ ] 6.2 Generate one `systemd.user.services.ansible` unit — oneshot, `become = false` passed to composition.
- [ ] 6.3 Emit `home.activation.ansible-check` using `systemctl --user is-failed ansible.service`.
- [ ] 6.4 Default `markerPath` to `$XDG_STATE_HOME/system-manager-ansible/ansible.done`.

## 7. Worked example — debian bootstrap

- [ ] 7.1 Author `examples/debian-host.nix` declaring `services.ansible = { enable = true; roles = { apt-repo = { … }; apt-packages = { after = [ "apt-repo" ]; … }; pam-line = { requires = [ "apt-packages" ]; … }; user-in-group = { … }; systemd-default-target = { priority = 50; … }; }; };` matching `dotfiles/modules/system-manager/debian/bootstrap.yml` semantics.
- [ ] 7.2 Verify the composed playbook renders semantics equivalent to the original (task list, PAM lines, docker user, apt calls batched).

## 8. Documentation

- [ ] 8.1 Root `README.md` — one-page quickstart: "declare `services.ansible`, get a systemd unit, fail loud on activation".
- [ ] 8.2 `roles/README.md` — role authoring guide (disk-role schema, inline-role shape, testing, publishing a new role).
- [ ] 8.3 `docs/nix-api.md` — reference for `lib.*` and the module option tree, generated from doc-comments where possible.
- [ ] 8.4 `docs/organization.md` — the three organizational approaches (primitive+intent-files, inline intent-roles, hybrid feature modules) with the "start with B, graduate to C if needed" recommendation. Prevents future contributors from re-litigating the debate.
- [ ] 8.5 Update `openspec/project.md` after archive with the ratified conventions.

## 9. Follow-ups (deferred; tracked as future changes)

- [ ] 9.1 `dotfiles` migration: replace `modules/system-manager/debian/` inline module with an import of `inputs.system-manager-ansible.systemManagerModules.default` + a `services.ansible = { … };` declaration. Delete the inline module once parity verified.
- [ ] 9.2 Per-role `async` opt-in for tasks whose latency justifies it.
- [ ] 9.3 Cross-role handler validation at build time (currently only validated at ansible runtime).
- [ ] 9.4 `wants` edge (soft activation) — add if a use case appears.
