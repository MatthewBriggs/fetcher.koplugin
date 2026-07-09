# Fetcher

A KOReader plugin providing a single sync button that updates itself, checks for KOReader updates, syncs new books from OPDS catalogs, and updates patches.

## Features

- **KOReader update check** — checks stable or nightly channel (configurable)
- **OPDS book sync** — downloads new books from selected catalogs with per-book progress
- **Patch & plugin sync** — updates user patches and whole plugins (including Fetcher itself) from configured GitHub repos
- **Single summary screen** — shows results of all sync steps, tap to dismiss
- Accessible from the main menu or ZenUI control panel

## Installation

Copy `fetcher.koplugin/` into your KOReader `plugins/` directory.

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
| Patch sources… | Enable/disable configured patch & plugin repos, including Fetcher itself |
| Individual patches… | Enable/disable individual synced patch files |

## Self-update

Fetcher updates itself the same way it updates any other plugin repo: it's a
built-in entry (`MatthewBriggs/fetcher.koplugin`, type `plugin`) always
present in the source list, toggleable from **Patch sources…** like any other
repo. On sync, if the repo's latest GitHub release tag differs from the last
installed tag, it downloads `main.lua` and `_meta.lua` from that tag and
replaces the running files, then prompts a restart.
