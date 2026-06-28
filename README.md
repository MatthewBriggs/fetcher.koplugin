# ReaderSync

A KOReader plugin providing a single sync button that checks for KOReader updates and syncs new books from OPDS catalogs.

## Features

- **KOReader update check** — checks stable or nightly channel (configurable)
- **OPDS book sync** — downloads new books from selected catalogs with per-book progress
- **Single summary screen** — shows results of all sync steps, tap to dismiss
- Accessible from the main menu or ZenUI control panel

## Installation

Copy `readersync.koplugin/` into your KOReader `plugins/` directory.

## Setup

1. Configure your OPDS catalogs in the OPDS Catalog plugin first
2. Go to **ReaderSync → Settings → Select OPDS catalogs** and tick the ones to sync
3. Set a sync folder in the OPDS Catalog plugin (Sync → Set sync folder)
4. Add a ReaderSync button to the ZenUI control panel via ZenUI Settings → Control → Customize buttons → pick "ReaderSync: Sync now"

## Settings

| Setting | Description |
|---------|-------------|
| KOReader update channel | Stable or nightly |
| Enable KOReader update | Toggle OTA check on/off |
| Enable OPDS book sync | Toggle book sync on/off |
| Select OPDS catalogs | Choose which catalogs to sync |
| Force re-download all books | Re-download everything on next sync (clears after one run) |
