# Fetcher

A KOReader plugin providing a single sync button that updates itself, checks for KOReader updates, syncs new books from OPDS catalogs, and keeps patches and plugins up to date.

## Features

- **KOReader update check** — checks stable or nightly channel (configurable)
- **OPDS book sync** — downloads new books from selected catalogs with per-book progress
- **Plugin sync** — updates whole plugins (including Fetcher itself) from their GitHub `.zip` releases, installing them fresh if missing
- **Patch sync** — updates individual `.lua` patch files from configured GitHub repos
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
| Plugin sources… | Manage whole-plugin sources (Fetcher, curated list, your own). Installed ones auto-update; tick a "not installed" one to install it |
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

Fetcher ships with a curated list of popular KOReader plugins as built-in
**plugin sources** — ZenUI, Bookends, Bookshelf, Appearance, SimpleUI,
AppStore, zlibrary, Legado, OPDS+, KoAssistant, AnnotationSync, Readeck,
ReaderMenuRedesign, HighlightSync, and BatteryGraph.

**Manage-if-installed:** a curated plugin that's **already on your device** is
kept updated automatically. One that **isn't installed** shows up in
**Plugin sources…** with a "not installed" label but is left alone until you
tick it — Fetcher never installs a plugin you didn't ask for. Fetcher itself
and anything in your `fetcher_sources.lua` are managed by default.

Each is installed from its GitHub release: a prebuilt `.zip` asset if the repo
ships one, otherwise the release tag's source zip. Fetcher strips the wrapping
folder (handling `<name>.koplugin/…`, `plugins/<name>.koplugin/…`, and source
zipballs alike), guards against unsafe paths, and extracts into a sibling of
Fetcher's own directory (e.g. `plugins/zen_ui.koplugin/`), creating it if
needed. A plugin whose repo nests its files in an unusual layout may not
install cleanly — untick it if so.

Update detection reads the version each plugin declares in its own `_meta.lua`
and compares it semantically to the release, so Fetcher won't re-install the
same version or downgrade a newer build. Plugins that don't declare a version
fall back to comparing the release tag.

## Adding your own sources

Copy [`fetcher_sources.lua.sample`](fetcher_sources.lua.sample) to your KOReader
`settings/` directory as `fetcher_sources.lua` to add extra patch or plugin
repos on top of the built-ins. Plugin entries can set `keep_files` to keep
user-created files (API keys, config) across updates. See that file for the
format.

## GitHub token (optional)

Fetcher works unauthenticated, but if you manage many repos or sync often you
can hit GitHub's 60-requests/hour API limit. When it does hit the limit,
Fetcher now short-circuits the remaining API calls and shows a warning telling
you when the limit resets, rather than reporting every source as "failed".

Dropping a personal-access token into `settings/fetcher_github_token.txt` on
your device raises the limit to 5000/hour.

### Security: use the smallest-scope token you can

Fetcher only makes **unauthenticated-equivalent public API reads** — it never
writes, never touches private data, never needs any repo permissions. The
token is just there to tell GitHub who's asking, so you get the higher rate
limit. So the safest possible token is one with **zero scopes and zero
repository access**: if it gets stolen (e.g. someone grabs your ereader), all
they can do with it is make public API GETs at 5000/hr — the same thing you
just used it for.

Recommended: create a **fine-grained** personal access token at
<https://github.com/settings/personal-access-tokens/new> with:

- **Repository access**: *Public Repositories (read-only)* — or even *No
  repositories* if that's an option in your GitHub setup.
- **Repository permissions**: leave everything at *No access*.
- **Account permissions**: leave everything at *No access*.
- **Expiration**: whatever you're comfortable with (30 / 90 / 365 days).

A classic ("legacy") PAT with no scopes ticked also works, and is a valid
fallback if fine-grained tokens aren't available for you.

**Do not** use a broad-scope token (`repo`, `workflow`, `gist`, `admin:*`) —
that would give an attacker who reads the file from a stolen device full
control of your GitHub repos, the ability to push malicious CI, etc. Fetcher
doesn't need any of that.

Once you have the token, save it in `settings/fetcher_github_token.txt` on
your device (one line, plain text). To revoke it later, delete it from
<https://github.com/settings/tokens> and Fetcher will fall back to
unauthenticated 60/hr.

## Development

- **Tests:** `lua tests/qa.lua` runs a headless test suite that loads the real
  `main.lua` against stubbed KOReader modules and exercises settings migration,
  default-off seeding, the plugin/patch menu split, and the full sync/extract
  path (including the zip-slip guard). No KOReader install required.
- **Release build:** `./build.sh` produces a root-wrapped `fetcher.koplugin.zip`
  ready to attach to a GitHub release or extract into `plugins/`.

## Acknowledgements

Several of Fetcher's plugin-handling ideas — deciding updates from a plugin's
own declared version, optional GitHub-token authentication, and keeping user
config files across updates — were inspired by
[Updates Manager](https://github.com/advokatb/updatesmanager.koplugin) by
advokatb. Fetcher's implementation is its own (Updates Manager is AGPL-3.0;
Fetcher is MIT), but credit is due for the approach. If you want a fuller,
more configurable updates manager, check theirs out.

Thanks also to the authors of the plugins Fetcher helps keep updated.

## License

[MIT](LICENSE).
