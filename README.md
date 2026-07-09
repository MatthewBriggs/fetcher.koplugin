# Fetcher

A KOReader plugin providing a single sync button that updates itself, checks for KOReader updates, syncs new books from OPDS catalogs, and keeps patches and plugins up to date.

## Features

- **KOReader update check** — checks stable or nightly channel (configurable)
- **OPDS book sync** — downloads new books from selected catalogs with per-book progress
- **Plugin sync** — updates whole plugins (including Fetcher itself) from their GitHub `.zip` releases, installing them fresh if missing
- **Patch sync** — updates individual `.lua` patch files from configured GitHub repos
- **Single summary screen** — shows results of all sync steps on separate lines, tap to dismiss
- Accessible from the main menu or ZenUI control panel

## Requirements

A reasonably recent KOReader (2023 or newer). Fetcher uses `ffi/archiver` for
zip extraction and `ProgressbarDialog` for download progress, both long present
in KOReader across Kobo, Kindle, PocketBook, Android, and the desktop build.

## Installation

Either:

- **Manual** — download `fetcher.koplugin.zip` from the [latest release](https://github.com/MatthewBriggs/fetcher.koplugin/releases/latest) and extract the `fetcher.koplugin/` folder into your KOReader `plugins/` directory, or
- **Git** — clone this repo as `fetcher.koplugin` inside `plugins/`.

Once installed, Fetcher keeps itself updated.

## Setup

1. Configure your OPDS catalogs in the OPDS Catalog plugin first
2. Go to **Fetcher → Settings → Select OPDS catalogs** and tick the ones to sync
3. Set a sync folder in the OPDS Catalog plugin (Sync → Set sync folder)
4. Add a Fetcher button to the ZenUI control panel via ZenUI Settings → Control → Customize buttons → pick "Fetcher: Sync now"

## Settings

| Setting | Description |
|---------|-------------|
| KOReader update channel | Stable or nightly |
| Enable KOReader update | Toggle OTA check on/off |
| Enable OPDS book sync | Toggle book sync on/off |
| Select OPDS catalogs | Choose which catalogs to sync |
| Force re-download all books | Re-download everything on next sync (clears after one run) |
| Plugin sources… | Enable/disable whole-plugin sources, including Fetcher itself |
| Patch sources… | Enable/disable individual `.lua` patch repos |
| Individual patches… | Enable/disable individual synced patch files |

## Self-update

Fetcher updates itself the same way it updates any other plugin: its own repo
(`MatthewBriggs/fetcher.koplugin`) is a built-in **plugin source**, always
present and enabled by default, toggleable from **Plugin sources…**. On sync,
if the repo's latest GitHub release tag differs from the last installed tag, it
downloads `main.lua` and `_meta.lua` from that tag, replaces the running files,
and prompts a restart.

## Built-in plugin updates

Fetcher ships with three other plugins as built-in **plugin sources**:

- [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin)
- [Bookends](https://github.com/AndyHazz/bookends.koplugin)
- [Appearance](https://github.com/Euphoriyy/appearance.koplugin)

They are **disabled by default** — Fetcher won't install anything you didn't
ask for. Tick the ones you want under **Plugin sources…** and they'll be
installed (fresh if missing) and kept current on each sync. A plugin already
present on your device stays enabled so it keeps updating.

Each is distributed as a single `.zip` release asset (the standard KOReader
plugin release format). Fetcher downloads the zip, auto-detects whether its
contents are wrapped in a root folder or flat, guards against unsafe paths, and
extracts it into a sibling directory of Fetcher's own (e.g.
`plugins/zen_ui.koplugin/`), creating it if needed.

## Adding your own sources

Copy [`fetcher_sources.lua.sample`](fetcher_sources.lua.sample) to your KOReader
`settings/` directory as `fetcher_sources.lua` to add extra patch or plugin
repos on top of the built-ins. See that file for the format.

## Development

- **Tests:** `lua tests/qa.lua` runs a headless test suite that loads the real
  `main.lua` against stubbed KOReader modules and exercises settings migration,
  default-off seeding, the plugin/patch menu split, and the full sync/extract
  path (including the zip-slip guard). No KOReader install required.
- **Release build:** `./build.sh` produces a root-wrapped `fetcher.koplugin.zip`
  ready to attach to a GitHub release or extract into `plugins/`.

## License

[MIT](LICENSE).
