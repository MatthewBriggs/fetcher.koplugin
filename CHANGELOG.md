# Changelog

All notable changes to Fetcher are documented here.

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
