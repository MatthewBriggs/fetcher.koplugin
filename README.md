# Fetcher

A KOReader plugin providing a single sync button that updates itself, checks for KOReader updates, syncs new books from OPDS catalogs, and updates patches.

## Features

- **Self-update** — updates the plugin itself from its GitHub releases
- **KOReader update check** — checks stable or nightly channel (configurable)
- **OPDS book sync** — downloads new books from selected catalogs with per-book progress
- **Patch sync** — updates user patches from configured GitHub repos
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
| Enable self-update | Toggle plugin self-update on/off |
| KOReader update channel | Stable or nightly |
| Enable KOReader update | Toggle OTA check on/off |
| Enable OPDS book sync | Toggle book sync on/off |
| Select OPDS catalogs | Choose which catalogs to sync |
| Force re-download all books | Re-download everything on next sync (clears after one run) |
| Patch sources… | Enable/disable configured patch repos |
| Individual patches… | Enable/disable individual synced patch files |
