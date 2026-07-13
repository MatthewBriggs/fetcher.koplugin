# Changelog

All notable changes to Fetcher are documented here.

## v0.9.4

- **Fix misleading book download count.** The progress dialog previously
  said e.g. "Downloading 1 of 16" when only 3 books would actually be
  downloaded (13 of the 16 were already in the local cache). Fetcher now
  pre-filters to real work and shows an accurate "Downloading 1 of 3".

## v0.9.3

- **One more curated plugin:** [BatteryGraph](https://github.com/ura23/batterygraph.koplugin)
  (battery-usage history graph). Curated list now 15.

## v0.9.2

- **Version now shown in Fetcher → Settings** (read live from `_meta.lua`), so
  it's easy to check which version is running after a self-update.

## v0.9.1

- **Rate-limit handling.** When Fetcher hits GitHub's API limit (60/hr
  unauthenticated, 5000/hr with a token), it now stops making doomed API
  requests part-way through and prepends a clear warning to the summary
  showing when the limit resets and, if no token is present, a hint about
  adding one. Previously every rate-limited source landed in "failed" with
  no explanation.
- **Expanded token security guidance** in the README: use a fine-grained PAT
  with public-read-only access (or a classic PAT with no scopes), never a
  broad-scope token, since Fetcher only needs authentication for a higher
  public-read rate limit.

## v0.9.0

- **UI reverted to the modal progress dialog** (as in v0.7.x). The persistent
  top status bar introduced in v0.8.0 turned out to fit poorly with what
  Fetcher actually is: a deliberate, one-tap action that takes seconds. A
  centered modal is clearer to read, less clever, and better matches user
  intent than a subtle top strip trying not to interrupt reading. The v0.8
  branch is deleted; the status bar module (`statusbar.lua`) is gone.
- **Kept from v0.8**: sync activity is logged to `settings/fetcher.log`, with
  a new **Tools → Fetcher → Show last sync log** menu item that displays the
  last ~80 lines in a scrollable dialog. Handy for diagnosing quiet syncs
  ("did it actually run? which sources were checked?").
- **Kept from v0.8**: an unexpected error inside the sync is now caught, the
  modal closes cleanly, and an error dialog is shown — so a crash can't leave
  a dangling progress dialog on top of the reader.

## v0.7.0

- **Smarter update detection.** Whether a plugin needs updating is now decided
  from the version it reports in its own `_meta.lua`, compared semantically
  against the release (so `1.10 > 1.2`, and a `-dev` build is never "downgraded"
  to the plain release of the same version). This self-corrects from what's
  actually on disk instead of a settings map that could drift. Plugins that
  don't declare a readable version fall back to the previous tag-based check.
- **GitHub token support.** Drop a personal-access token in
  `settings/fetcher_github_token.txt` to raise the GitHub API limit from 60 to
  5000 requests/hour; API calls are also lightly rate-limited. No token still
  works fine.
- **`keep_files`.** Plugin updates now keep user-created files (API keys,
  configuration) across the refresh. Configured for AppStore
  (`appstore_configuration.lua`) and KoAssistant (`apikeys.lua`,
  `configuration.lua`, …); you can set `keep_files` on your own
  `fetcher_sources.lua` plugin entries too.
- **Two more curated plugins:** Bookshelf and SimpleUI (now 14).

## v0.6.1

- **Atomic plugin installs.** Plugins now extract into a staging folder that is
  swapped into place only after a *complete* extraction. A truncated download,
  a corrupt archive, or a mid-extraction error can no longer leave a
  half-installed (broken) plugin — a failed update leaves the previous version
  untouched. As a bonus, a successful update replaces the whole folder, so
  files removed upstream no longer linger.
- **Per-source isolation.** An unexpected error while processing one source
  (bad archive, disk full, …) now fails just that source instead of aborting
  the rest of the sync.

## v0.6.0

- **Curated plugin catalog:** the built-in plugin list grew from 3 to 12 popular
  KOReader plugins (zen_ui, bookends, appearance, appstore, zlibrary, legado,
  opds_plus, koassistant, AnnotationSync, readeck, zzz-readermenuredesign,
  highlightsync).
- **Manage-if-installed policy:** a curated plugin that's **already installed**
  is kept updated automatically; one that **isn't installed** is shown in
  **Plugin sources…** (with an "installed / not installed" label) but is only
  installed if you tick it. No plugin is ever installed unprompted. Your own
  `fetcher_sources.lua` entries and Fetcher itself stay managed by default.
- **Better zip extraction:** the extractor now strips the longest common
  directory, so plugins packaged as `plugins/<name>.koplugin/…` (e.g. legado,
  zlibrary) install correctly instead of ending up double-nested.
- **Source-zipball fallback:** plugins whose release doesn't attach a prebuilt
  `.zip` can now be installed from the release tag's source zip, which also
  makes `fetcher_sources.lua` work for far more community plugins.
- Replaced the one-time "seed disabled" hack with the live manage-if-installed
  rule; old disable choices migrate automatically.

## v0.5.0

- Wi-Fi: the sync now checks `isConnected()` and runs KOReader's connect flow
  (turn Wi-Fi on / prompt, per your settings) before doing any network work,
  instead of relying only on `isOnline()` (a DNS check that could pass on stale
  state and let the sync run while Wi-Fi was actually off).
- Status dialog: the heading stays "Plugins & patches" for the whole step
  instead of flickering between "Plugins" and "Patches" as sources are checked.
- Built-in plugin sources (ZenUI, Bookends, Appearance) now default to
  **disabled** on a fresh install, so Fetcher never installs plugins you
  didn't ask for. Enable any of them under **Plugin sources…**. Plugins
  already present on the device are left enabled.
- User-configured `type = "plugin"` sources no longer need an explicit `dir`;
  they install to `plugins/<repo-basename>/` automatically.
- Added a MIT license, a `fetcher_sources.lua.sample` template, and a
  `build.sh` that produces a `fetcher.koplugin.zip` release asset.

## v0.4.0

- Keep three plugins up to date, installing them fresh if missing, from their
  prebuilt `.zip` release assets (extracted with `ffi/archiver`, auto-detecting
  a wrapping root folder, with a zip-slip guard):
  ZenUI, Bookends, Appearance.
- Split **Plugin sources…** and **Patch sources…** into separate menus; the
  sync summary reports plugins and patches on separate lines.
- One-time migration copies legacy `readersync*.lua` settings to `fetcher*.lua`
  so nothing configured under the old name is lost.

## v0.3.0

- Renamed the plugin from **ReaderSync** to **Fetcher**.
- Fetcher self-updates from its own GitHub releases, as a built-in entry in
  the same source list used for patches.

## v0.2.0

- Patch sync, download progress bars, URL-based book de-duplication.

## v0.1.0

- Initial release: one-tap KOReader OTA update check and OPDS book sync.
