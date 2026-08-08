# Exports each disk role as `roles.<name> = ./roles/<name>` so callers can use
# them programmatically. Not strictly required — the module discovers roles
# from `rolesDir` automatically — but useful for cross-flake introspection.
{ rolesDir }:
let
  entries = builtins.readDir rolesDir;
  dirs = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);
in
builtins.listToAttrs (map (n: {
  name = n;
  value = rolesDir + "/${n}";
}) dirs)
