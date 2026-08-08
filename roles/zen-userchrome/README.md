# zen-userchrome

Idempotently extract userchrome / bootloader archive bundles (Sine, Fx
Autoconfig, etc.) into a Zen browser flatpak profile.

## Options (Nix)

| Option | Type | Default | Description |
|---|---|---|---|
| `zenDir` | `str` | *required* | Absolute path to the flatpak's `.zen` dir (contains `profiles.ini`). |
| `profileArchives` | `listOf { src, creates }` | `[]` | Archives extracted into `<default-profile>/chrome/`. |
| `programArchives` | `listOf { src, dest, creates }` | `[]` | Archives extracted into arbitrary absolute destinations (e.g. the flatpak program dir). |

## Behaviour

1. Stat `{{ zenDir }}/profiles.ini`. If absent → `end_play` (Zen not yet run).
2. Slurp + regex-parse the `[Install*]` `Default=` line to find the default profile.
3. Ensure `<profile>/chrome/` exists.
4. Extract each `profileArchives[*]` into `<profile>/chrome/`, guarded by a
   sentinel path (`creates:`).
5. Extract each `programArchives[*]` into its `dest`, guarded by a sentinel.

## Example (home-manager)

```nix
{
  ansnix.enable = true;
  ansnix.roles.zen-userchrome = {
    vars = {
      zenDir = "${config.home.homeDirectory}/.var/app/app.zen_browser.zen/.zen";
      profileArchives = [
        { src = profileZip; creates = "utils/chrome.manifest"; }
        { src = engineZip;  creates = "engine.json"; }
      ];
      programArchives = [
        { src = programZip;
          dest = "/var/lib/flatpak/app/app.zen_browser.zen/current/active/files/zen";
          creates = "/var/lib/flatpak/app/app.zen_browser.zen/current/active/files/zen/config.js"; }
      ];
    };
  };
}
```

## Caveats

- `programArchives` writing under `/var/lib/flatpak/.../current/active/` is
  best-effort — flatpak updates swap the `active` symlink and files under
  the old commit disappear. For per-user flatpak installs, target
  `~/.local/share/flatpak/...` instead. This is a Zen/flatpak layout
  reality, not a role limitation.
