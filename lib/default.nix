{ lib }:

let
  # ── readRole ──────────────────────────────────────────────────────────────
  readRole =
    roleDir:
    let
      name = baseNameOf (toString roleDir);
      nixOptionsPath = roleDir + "/meta/nix-options.nix";
      hasNixOptions = builtins.pathExists nixOptionsPath;
      nixOptions =
        if hasNixOptions then
          import nixOptionsPath { inherit lib; }
        else
          {
            options = { };
            checkable = false;
          };
    in
    {
      inherit name nixOptions hasNixOptions;
      path = roleDir;
      checkable = nixOptions.checkable or false;
      hasReadme = builtins.pathExists (roleDir + "/README.md");
    };

  # ── discoverRoles ─────────────────────────────────────────────────────────
  discoverRoles =
    rolesDir:
    let
      entries = builtins.readDir rolesDir;
      dirNames = lib.filterAttrs (n: t: t == "directory" && !(lib.hasPrefix "." n)) entries;
    in
    lib.mapAttrs (n: _: readRole (rolesDir + "/${n}")) dirNames;

  # ── generateInlineRole ────────────────────────────────────────────────────
  generateInlineRole =
    pkgs:
    {
      name,
      tasks,
      handlers ? [ ],
      checkable ? false,
    }:
    let
      yamlFormat = pkgs.formats.yaml { };
      tasksFile = yamlFormat.generate "${name}-tasks.yml" tasks;
      handlersFile = yamlFormat.generate "${name}-handlers.yml" handlers;
      metaFile = yamlFormat.generate "${name}-meta.yml" {
        galaxy_info = {
          role_name = name;
          min_ansible_version = "2.14";
        };
        dependencies = [ ];
      };
    in
    pkgs.runCommandLocal "inline-role-${name}" { } (''
      mkdir -p $out/${name}/tasks $out/${name}/meta
      cp ${tasksFile} $out/${name}/tasks/main.yml
      cp ${metaFile} $out/${name}/meta/main.yml
      echo "# ${name} (inline role, auto-generated)" > $out/${name}/README.md
    '' + (if handlers != [ ] then ''
      mkdir -p $out/${name}/handlers
      cp ${handlersFile} $out/${name}/handlers/main.yml
    '' else ""));

  # ── topoSort ──────────────────────────────────────────────────────────────
  topoSort =
    {
      names,
      edges,
      priority,
    }:
    let
      allNames = lib.unique names;
      liveEdges = lib.foldl' (
        acc: from:
        acc
        // {
          ${from} = lib.filter (t: builtins.elem t allNames) (edges.${from} or [ ]);
        }
      ) { } allNames;

      inDegree0 = lib.genAttrs allNames (_: 0);
      inDegree = lib.foldl' (
        acc: from: lib.foldl' (a: to: a // { ${to} = a.${to} + 1; }) acc liveEdges.${from}
      ) inDegree0 allNames;

      compareNodes =
        a: b:
        let
          pa = priority.${a} or 100;
          pb = priority.${b} or 100;
        in
        if pa != pb then pa < pb else a < b;
      sortFrontier = frontier: lib.sort compareNodes frontier;

      step =
        state:
        let
          frontier = sortFrontier (
            lib.filter (n: state.deg.${n} == 0 && !(state.done.${n} or false)) allNames
          );
        in
        if frontier == [ ] then
          state
        else
          let
            n = builtins.head frontier;
            newDeg = lib.foldl' (d: to: d // { ${to} = d.${to} - 1; }) state.deg liveEdges.${n};
          in
          step {
            order = state.order ++ [ n ];
            deg = newDeg;
            done = state.done // { ${n} = true; };
          };

      final = step {
        order = [ ];
        deg = inDegree;
        done = { };
      };
    in
    if builtins.length final.order != builtins.length allNames then
      let
        remaining = lib.filter (n: !(final.done.${n} or false)) allNames;
      in
      throw ''
        ansnix: dependency cycle detected among roles: ${lib.concatStringsSep ", " remaining}
        Inspect the .after / .before / .requires edges of those roles to break the cycle.
      ''
    else
      final.order;

  # ── composePlaybook ───────────────────────────────────────────────────────
  composePlaybook =
    {
      pkgs,
      name,
      roles,
      roleDefs,
      become ? true,
      extraVars ? { },
    }:
    let
      yamlFormat = pkgs.formats.yaml { };
      jsonFormat = pkgs.formats.json { };

      enabled = lib.filterAttrs (_: r: r.enable or true) roles;
      allNames = builtins.attrNames enabled;

      # Validate 'requires'
      _validated = builtins.foldl' (
        _: n:
        let
          req = enabled.${n}.requires or [ ];
          missing = lib.filter (r: !(builtins.elem r allNames)) req;
        in
        if missing == [ ] then null else throw "ansnix.roles.${n}.requires references role(s) not declared or disabled: ${lib.concatStringsSep ", " missing}"
      ) null allNames;

      # Assert each enabled role has something to run
      _bodied = builtins.foldl' (
        _: n:
        let
          r = enabled.${n};
          hasDisk = roleDefs ? ${n};
          hasInline = (r.tasks or [ ]) != [ ];
        in
        if hasDisk || hasInline then null else throw "ansnix.roles.${n}: neither a disk role at roles/${n}/ nor inline tasks — nothing to run."
      ) null allNames;

      # Build edges
      edges = lib.foldl' (
        acc: n:
        let
          r = enabled.${n};
          afterList = r.after or [ ];
          reqList = r.requires or [ ];
          beforeList = r.before or [ ];
          withAfter = lib.foldl' (
            a: x: a // { ${x} = (a.${x} or [ ]) ++ [ n ]; }
          ) acc (afterList ++ reqList);
          withBefore = lib.foldl' (
            a: x: a // { ${n} = (a.${n} or [ ]) ++ [ x ]; }
          ) withAfter beforeList;
        in
        withBefore
      ) (lib.genAttrs allNames (_: [ ])) allNames;

      priorityMap = lib.mapAttrs (_: r: r.priority or 100) enabled;

      orderedRoles = topoSort {
        names = allNames;
        inherit edges;
        priority = priorityMap;
      };

      commonFields = [
        "enable"
        "priority"
        "tasks"
        "handlers"
        "after"
        "before"
        "requires"
        "checkable"
      ];

      resolveRole =
        n:
        let
          r = enabled.${n};
          hasDisk = roleDefs ? ${n};
          hasInline = (r.tasks or [ ]) != [ ];
          varsAttrs = lib.filterAttrs (k: _: !(builtins.elem k commonFields)) r;
          inlineName = if hasDisk then "${n}-extras" else n;
          inlineDrv =
            if hasInline then
              generateInlineRole pkgs {
                name = inlineName;
                tasks = r.tasks;
                handlers = r.handlers or [ ];
                checkable = r.checkable or false;
              }
            else
              null;
        in
        {
          inherit n hasDisk hasInline varsAttrs inlineName inlineDrv;
          diskPath = if hasDisk then roleDefs.${n}.path else null;
        };

      resolved = map resolveRole orderedRoles;

      diskRoleParents = lib.unique (map (r: dirOf (toString r.diskPath)) (lib.filter (r: r.hasDisk) resolved));
      inlineRolePaths = map (r: toString r.inlineDrv) (lib.filter (r: r.hasInline) resolved);
      rolesPath = lib.concatStringsSep ":" (diskRoleParents ++ inlineRolePaths);

      mkTasksForRole =
        r:
        (lib.optional r.hasDisk {
          name = "${r.n} (disk role)";
          "ansible.builtin.import_role" = { name = r.n; };
          vars = r.varsAttrs;
        })
        ++ (lib.optional r.hasInline {
          name = "${r.n} (inline${lib.optionalString r.hasDisk " extras"})";
          "ansible.builtin.import_role" = { name = r.inlineName; };
        });

      allTasks = lib.concatMap mkTasksForRole resolved;

      playbookBody = [
        {
          hosts = "localhost";
          connection = "local";
          become = become;
          gather_facts = true;
          tasks = allTasks;
        }
      ];

      playbookFile = yamlFormat.generate "${name}-playbook.yml" playbookBody;
      extraVarsFile =
        if extraVars == { } then null else jsonFormat.generate "${name}-extra-vars.json" extraVars;
    in
    {
      inherit playbookFile extraVarsFile orderedRoles rolesPath;
    };

  # ── mkPlaybookRunner ──────────────────────────────────────────────────────
  mkPlaybookRunner =
    {
      pkgs,
      package,
      playbookFile,
      extraVarsFile ? null,
      rolesPath,
      name ? "ansnix-runner",
    }:
    let
      extraVarsArg = if extraVarsFile != null then "--extra-vars @${extraVarsFile}" else "";
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        package
        pkgs.python3
        pkgs.gnupg
        pkgs.gnutar
        pkgs.gzip
        pkgs.coreutils
      ];
      text = ''
        set -euo pipefail
        export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
        export ANSIBLE_ROLES_PATH="${rolesPath}"
        exec ansible-playbook \
          --connection=local \
          --inventory=localhost, \
          ${extraVarsArg} \
          ${playbookFile}
      '';
    };

in
{
  inherit
    readRole
    discoverRoles
    generateInlineRole
    topoSort
    composePlaybook
    mkPlaybookRunner
    ;
  moduleApiVersion = 1;
}
