-- Headless QA harness for Fetcher.
-- Loads the REAL main.lua against stubbed KOReader modules and exercises the
-- actual code: migration, default-OFF seeding, the plugin/patch menu split,
-- getSources shape, and syncSources end-to-end with a mocked network +
-- archiver (real filesystem in a temp workspace). No KOReader needed.
--
--   Run:  lua tests/qa.lua
--   (optionally: lua tests/qa.lua <path-to-main.lua> <temp-work-dir>)

local here = (arg[0] or ""):match("^(.*/)") or "./"
local MAIN = arg[1] or (here .. "../main.lua")
local WORK = arg[2] or ((os.getenv("TMPDIR") or "/tmp") .. "/fetcher_qa_work")

------------------------------------------------------------------- helpers ---
local passed, failed = 0, 0
local function ok(name, cond, detail)
    if cond then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "")) end
end
local function exists(path)
    local r = os.execute('test -e "' .. path .. '"')
    return r == true or r == 0
end
local function sh(cmd) os.execute(cmd) end
local function rmrf(p) sh('rm -rf "' .. p .. '"') end
local function mkdirp(p) sh('mkdir -p "' .. p .. '"') end
local function writefile(p, s) local f = assert(io.open(p, "w")); f:write(s); f:close() end
local function readfile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- Minimal Lua table serializer for the LuaSettings stub.
local function ser(v, indent)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        local parts = { "{\n" }
        for k, val in pairs(v) do
            local key = (type(k) == "number") and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            parts[#parts + 1] = indent .. "  " .. key .. " = " .. ser(val, indent .. "  ") .. ",\n"
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts)
    end
    return "nil"
end

------------------------------------------------------------- workspace dirs ---
local SETTINGS = WORK .. "/settings"
local DATA = WORK .. "/data"
local PLUGINS = WORK .. "/plugins"
rmrf(WORK); mkdirp(SETTINGS); mkdirp(DATA); mkdirp(PLUGINS)

------------------------------------------------------------------- stubs ------
-- Shared mock state driven per-test.
local FIXTURES = {}         -- github api url -> release table
local PENDING_JSON = nil     -- next rapidjson.decode result
local ARCHIVE_ENTRIES = {}   -- zip path -> list of { path, mode }
local extract_calls = {}     -- record of extractToPath dest paths

local function preload(name, mod) package.loaded[name] = mod end

preload("datastorage", {
    getSettingsDir = function() return SETTINGS end,
    getDataDir = function() return DATA end,
})
preload("gettext", setmetatable({}, { __call = function(_, s) return s end }))

-- ffi/util.template — %1, %2 … substitution.
preload("ffi/util", { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)]) end))
end })

-- LuaSettings: seeds from the real file (dofile) on open, persists via ser().
local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path)
    local o = setmetatable({ _path = path, _data = {} }, LuaSettings)
    if exists(path) then
        local good, t = pcall(dofile, path)
        if good and type(t) == "table" then o._data = t end
    end
    return o
end
function LuaSettings:readSetting(k, default)
    local v = self._data[k]
    if v == nil then return default end
    return v
end
function LuaSettings:saveSetting(k, v) self._data[k] = v; return self end
function LuaSettings:delSetting(k) self._data[k] = nil; return self end
function LuaSettings:flush() writefile(self._path, "return " .. ser(self._data, "")) end
function LuaSettings:close() end
preload("luasettings", LuaSettings)

-- lfs: real filesystem via shell.
preload("libs/libkoreader-lfs", {
    attributes = function(path) if exists(path) then return { mode = "file" } end return nil end,
    mkdir = function(path) mkdirp(path) return true end,
})
preload("util", { makePath = function(path) mkdirp(path) return true end })

-- ltn12 sinks.
preload("ltn12", {
    sink = {
        table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end,
        file = function(fh) return function(chunk) if chunk then fh:write(chunk) else fh:close() end return 1 end end,
        null = function() return function() return 1 end end,
    },
})

-- socket / socketutil.
preload("socket", {
    skip = function(n, ...) local t = { ... }; for _ = 1, n do table.remove(t, 1) end return table.unpack(t) end,
    sleep = function() end,
})
preload("socketutil", {
    FILE_BLOCK_TIMEOUT = 1, FILE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end, reset_timeout = function() end,
    chainSinkWithProgressCallback = function(sink, _cb) return sink end,
})
preload("socket.http", { request = function() return 1, 200, {} end })

-- ssl.https: handles github api (GET json), HEAD (no redirect), file download.
preload("ssl.https", { request = function(t)
    if t.method == "HEAD" then return 1, 200, {} end
    if t.url:find("api.github.com") then
        PENDING_JSON = FIXTURES[t.url]
        if t.sink then t.sink("json"); t.sink(nil) end
        return 1, (PENDING_JSON and 200 or 404)
    end
    -- file download: write dummy bytes so the temp file is created
    if t.sink then t.sink("BYTES"); t.sink(nil) end
    return 1, 200
end })

preload("rapidjson", { decode = function(_) return PENDING_JSON end })

-- ffi/archiver mock: iterate returns fixture entries; extractToPath writes file.
local Archiver = { Reader = {} }
Archiver.Reader.__index = Archiver.Reader
function Archiver.Reader:new() return setmetatable({}, Archiver.Reader) end
function Archiver.Reader:open(path) self._path = path; self._entries = ARCHIVE_ENTRIES[path] or {}; return true end
function Archiver.Reader:iterate()
    local i = 0
    return function() i = i + 1; return self._entries[i] end
end
function Archiver.Reader:extractToPath(_archive_path, dest_path)
    extract_calls[#extract_calls + 1] = dest_path
    writefile(dest_path, "extracted")
    return true
end
function Archiver.Reader:close() end
preload("ffi/archiver", Archiver)

-- UI stubs.
local ui_shown = {}
preload("ui/uimanager", {
    show = function(_, w) ui_shown[#ui_shown + 1] = w end,
    close = function() end, forceRePaint = function() end,
    scheduleIn = function() end, nextTick = function(_, fn) if fn then fn() end end,
    restartKOReader = function() end,
})
local function widgetstub() return setmetatable({}, { __index = function() return function() end end }) end
preload("ui/widget/infomessage", setmetatable({}, { __index = function() return function() return widgetstub() end end, __call = function() return widgetstub() end }))
preload("ui/widget/confirmbox", { new = function() return widgetstub() end })
preload("ui/widget/progressbardialog", { new = function() return {
    show = function() end, close = function() end, reportProgress = function() end,
} end })
preload("ui/network/manager", { runWhenOnline = function(_, fn) fn() end })
preload("ui/otamanager", {
    getOTAType = function() return "none" end,
    checkUpdate = function() return 0 end,
    genChannelList = function() return {} end,
    fetchAndProcessUpdate = function() end,
})
preload("dispatcher", { registerAction = function() end, execute = function() end, menuTextFunc = function() return "x" end })
preload("opdsbrowser", { new = function() return { fillPendingSyncs = function() end, pending_syncs = {} } end })

-- WidgetContainer:extend metaclass.
local WidgetContainer = {}
function WidgetContainer:extend(t)
    t = t or {}
    setmetatable(t, { __index = self })
    t.extend = WidgetContainer.extend
    t.new = function(cls, o) o = o or {}; setmetatable(o, { __index = cls }); return o end
    return t
end
preload("ui/widget/container/widgetcontainer", WidgetContainer)

------------------------------------------------------------ load main.lua ----
local Fetcher = dofile(MAIN)
ok("main.lua loads and returns a table", type(Fetcher) == "table")

-- Fresh instance; pin plugin dirs into the temp workspace.
local function newInstance()
    local f = Fetcher:new{ ui = { menu = { registerToMainMenu = function() end } } }
    f.settings = nil
    f.settings_file = SETTINGS .. "/fetcher.lua"
    f.getPluginsParentDir = function() return PLUGINS .. "/" end
    f.getSelfDir = function() return PLUGINS .. "/fetcher.koplugin/" end
    return f
end

print("\n== migration ==")
do
    -- Simulate a device with legacy readersync settings, no fetcher files.
    os.remove(SETTINGS .. "/fetcher.lua"); os.remove(SETTINGS .. "/fetcher_sources.lua")
    writefile(SETTINGS .. "/readersync.lua", 'return { ["opds_catalog_urls"] = { [1] = "http://x/opds" }, ["disabled_patch_repos"] = { [1] = "some/repo" } }')
    writefile(SETTINGS .. "/readersync_sources.lua", 'return { { repo = "u/koreader-patches" } }')

    local f = newInstance()
    f:migrateLegacySettings()
    ok("migration creates fetcher.lua", exists(SETTINGS .. "/fetcher.lua"))
    ok("migration creates fetcher_sources.lua", exists(SETTINGS .. "/fetcher_sources.lua"))
    local migrated = dofile(SETTINGS .. "/fetcher_sources.lua")
    ok("migrated patch source preserved", migrated[1] and migrated[1].repo == "u/koreader-patches")
    local st = dofile(SETTINGS .. "/fetcher.lua")
    ok("migrated OPDS catalog preserved", st.opds_catalog_urls and st.opds_catalog_urls[1] == "http://x/opds")

    -- Idempotent: existing fetcher.lua must NOT be clobbered.
    writefile(SETTINGS .. "/fetcher.lua", 'return { ["sentinel"] = true }')
    f = newInstance(); f:migrateLegacySettings()
    ok("migration does not overwrite existing fetcher.lua", dofile(SETTINGS .. "/fetcher.lua").sentinel == true)
end

print("\n== default-OFF seeding ==")
do
    -- Clean slate: no plugins installed on device.
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS)
    local f = newInstance()
    f:seedDefaultDisabledPlugins()
    local disabled = f:getSetting("disabled_patch_repos", {})
    local set = {}; for _, r in ipairs(disabled) do set[r] = true end
    ok("zen_ui seeded disabled", set["AnthonyGress/zen_ui.koplugin"] == true)
    ok("bookends seeded disabled", set["AndyHazz/bookends.koplugin"] == true)
    ok("appearance seeded disabled", set["Euphoriyy/appearance.koplugin"] == true)
    ok("self repo NOT disabled", set["MatthewBriggs/fetcher.koplugin"] ~= true)
    ok("seeded flag set", f:getSetting("builtin_defaults_seeded", false) == true)

    -- Idempotent: re-enabling then re-seeding must not re-disable.
    f:saveSetting("disabled_patch_repos", {})
    f:seedDefaultDisabledPlugins()
    ok("re-seed is a no-op after flag set", #f:getSetting("disabled_patch_repos", {}) == 0)

    -- Already-installed plugin is left enabled.
    rmrf(SETTINGS); mkdirp(SETTINGS)
    mkdirp(PLUGINS .. "/zen_ui.koplugin")
    f = newInstance(); f:seedDefaultDisabledPlugins()
    disabled = f:getSetting("disabled_patch_repos", {})
    set = {}; for _, r in ipairs(disabled) do set[r] = true end
    ok("installed plugin stays enabled", set["AnthonyGress/zen_ui.koplugin"] ~= true)
    ok("uninstalled plugin still disabled", set["AndyHazz/bookends.koplugin"] == true)
    rmrf(PLUGINS .. "/zen_ui.koplugin")
end

print("\n== getSources shape ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    writefile(SETTINGS .. "/fetcher_sources.lua",
        'return { { repo = "u/patches" }, { repo = "u/thing.koplugin", type = "plugin" } }')
    local f = newInstance()
    local sources = f:getSources()
    local byrepo = {}; for _, s in ipairs(sources) do byrepo[s.repo] = s end
    ok("self is a plugin source with files list", byrepo["MatthewBriggs/fetcher.koplugin"]
        and byrepo["MatthewBriggs/fetcher.koplugin"].files ~= nil)
    ok("built-in zip plugin has dir, no files", byrepo["AnthonyGress/zen_ui.koplugin"]
        and byrepo["AnthonyGress/zen_ui.koplugin"].dir and byrepo["AnthonyGress/zen_ui.koplugin"].files == nil)
    ok("user plugin source got dir backfilled", byrepo["u/thing.koplugin"]
        and byrepo["u/thing.koplugin"].dir == PLUGINS .. "/thing.koplugin/")
    ok("user patch source has no plugin type", byrepo["u/patches"] and byrepo["u/patches"].type ~= "plugin")
end

print("\n== menu split ==")
do
    local f = newInstance()
    local plugin_items = f:genPluginMenuItems()
    local patch_items = f:genSourceMenuItems()
    local ptext = {}; for _, it in ipairs(plugin_items) do ptext[it.text] = true end
    local qtext = {}; for _, it in ipairs(patch_items) do qtext[it.text] = true end
    ok("Plugin sources lists self", ptext["MatthewBriggs/fetcher.koplugin"] == true)
    ok("Plugin sources lists zip plugins", ptext["AnthonyGress/zen_ui.koplugin"] == true)
    ok("Plugin sources excludes patch repo", ptext["u/patches"] ~= true)
    ok("Patch sources lists patch repo", qtext["u/patches"] == true)
    ok("Patch sources excludes plugins", qtext["MatthewBriggs/fetcher.koplugin"] ~= true)
end

print("\n== syncSources end-to-end ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    local f = newInstance()

    local ZIP_REPO = "test/zilch.koplugin"
    local PATCH_REPO = "test/patches"
    local zilch_dir = PLUGINS .. "/zilch.koplugin/"
    f.getSources = function()
        return {
            { repo = ZIP_REPO, type = "plugin", dir = zilch_dir },
            { repo = PATCH_REPO },
        }
    end

    local api = function(repo) return "https://api.github.com/repos/" .. repo .. "/releases/latest" end
    FIXTURES = {
        [api(ZIP_REPO)] = { tag_name = "v1.0.0", assets = {
            { name = "zilch.koplugin.zip", browser_download_url = "https://dl/zilch.zip", size = 100 } } },
        [api(PATCH_REPO)] = { tag_name = "v2.0.0", assets = {
            { name = "cool.lua", browser_download_url = "https://dl/cool.lua", size = 10 } } },
    }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/zilch.koplugin.zip"] = {
        { path = "zilch.koplugin/main.lua", mode = "file" },
        { path = "zilch.koplugin/_meta.lua", mode = "file" },
        { path = "zilch.koplugin/", mode = "directory" },
    } }
    extract_calls = {}

    local needs_restart, plugin_line, patch_line = f:syncSources()
    ok("plugin installed: main.lua extracted, prefix stripped", exists(zilch_dir .. "main.lua"))
    ok("plugin installed: _meta.lua extracted", exists(zilch_dir .. "_meta.lua"))
    ok("no double-nested dir", not exists(zilch_dir .. "zilch.koplugin"))
    ok("patch downloaded to patches/", exists(DATA .. "/patches/cool.lua"))
    ok("plugin_line reports 1 updated", plugin_line == "Plugins: 1 updated ✓", plugin_line)
    ok("patch_line reports 1 updated", patch_line == "Patches: 1 updated ✓", patch_line)
    ok("needs_restart true after updates", needs_restart == true)
    ok("tmp zip cleaned up", not exists(DATA .. "/fetcher_tmp/zilch.koplugin.zip"))

    -- Re-run: both now up to date, nothing downloaded.
    extract_calls = {}
    local nr2, pl2, ql2 = f:syncSources()
    ok("second run: plugins up to date", pl2 == "Plugins: up to date ✓", pl2)
    ok("second run: patches up to date", ql2 == "Patches: up to date ✓", ql2)
    ok("second run: no extraction", #extract_calls == 0)
    ok("second run: no restart needed", nr2 == false)
end

print("\n== syncSources zip-slip guard ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    local f = newInstance()
    local EVIL = "test/evil.koplugin"
    local evil_dir = PLUGINS .. "/evil.koplugin/"
    f.getSources = function() return { { repo = EVIL, type = "plugin", dir = evil_dir } } end
    FIXTURES = { ["https://api.github.com/repos/" .. EVIL .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "evil.koplugin.zip", browser_download_url = "https://dl/evil.zip", size = 1 } } } }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/evil.koplugin.zip"] = {
        { path = "evil.koplugin/ok.lua", mode = "file" },
        { path = "evil.koplugin/../../escape.lua", mode = "file" },
    } }
    extract_calls = {}
    local _nr, pline = f:syncSources()
    ok("zip-slip archive reported as failed", pline == "Plugins: 0 updated, failed: evil.koplugin", pline)
    ok("no file escaped the destination", not exists(PLUGINS .. "/escape.lua") and not exists(WORK .. "/escape.lua"))
    ok("installed tag NOT recorded on failure", f:getSetting("patch_installed_tags", {})[EVIL] == nil)
end

print("\n== other menu generators ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    -- Individual patches menu from cached known_patches.
    f:saveSetting("known_patches", { ["u/patches"] = { "a.lua", "b.lua" } })
    local pitems = f:genPatchMenuItems()
    local names = {}; for _, it in ipairs(pitems) do names[it.text] = true end
    ok("Individual patches lists cached patch names", names["a.lua"] and names["b.lua"])

    -- OPDS catalog menu from an opds.lua fixture.
    writefile(SETTINGS .. "/opds.lua",
        'return { ["servers"] = { { url = "http://s/opds", title = "My Catalog" } } }')
    local citems = f:genCatalogMenuItems()
    ok("OPDS catalog menu reflects configured servers", citems[1] and citems[1].text == "My Catalog")

    -- Empty case placeholder doesn't error.
    rmrf(SETTINGS); mkdirp(SETTINGS)
    f = newInstance()
    ok("empty patches menu returns a placeholder", f:genPatchMenuItems()[1] ~= nil)
    ok("empty catalog menu returns a placeholder", f:genCatalogMenuItems()[1] ~= nil)
end

print("\n== runSync smoke (update+opds disabled) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    f:saveSetting("enable_koreader_update", false)
    f:saveSetting("enable_opds_sync", false)
    f.getSources = function() return {} end
    ui_shown = {}
    local good, err = pcall(function() f:runSync() end)
    ok("runSync completes without error", good, err)
    ok("runSync shows a summary widget", #ui_shown >= 1)
end

print(string.format("\n==== %d passed, %d failed ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
