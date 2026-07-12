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
local STATUS_LOG = {}        -- record of every ProgressbarDialog title/subtitle
local BEFORE_WIFI_CB = nil   -- last callback passed to NetworkMgr:beforeWifiAction
local CODELOAD_HIT = false   -- set when a codeload.github.com URL is downloaded
-- Failure-injection knobs for edge-case tests (reset per test):
local ARCHIVE_OPEN_FAIL = false  -- Reader:open returns false (corrupt zip)
local EXTRACT_FAIL_AT = nil      -- extractToPath returns false on the Nth call
local EXTRACT_ATTEMPTS = 0       -- running count of extractToPath calls
local DOWNLOAD_FAIL = false      -- file downloads return HTTP 500
local THROW_ON_REPO = nil        -- error() when this repo's API URL is fetched
local LAST_API_AUTH = nil        -- Authorization header seen on the last API call

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

-- lfs: real filesystem via shell, accurate enough for removeTree/swapIntoPlace.
local function isdir(p) local r = os.execute('test -d "' .. p .. '"'); return r == true or r == 0 end
local function isfile(p) local r = os.execute('test -f "' .. p .. '"'); return r == true or r == 0 end
preload("libs/libkoreader-lfs", {
    attributes = function(path, req)
        local mode = isdir(path) and "directory" or (isfile(path) and "file" or nil)
        if req == "mode" then return mode end
        if mode == nil then return nil end
        return { mode = mode }
    end,
    mkdir = function(path) mkdirp(path) return true end,
    rmdir = function(path) return os.execute('rmdir "' .. path .. '"') and true or nil end,
    dir = function(path)
        local entries = { ".", ".." }
        local p = io.popen('ls -1A "' .. path .. '" 2>/dev/null')
        if p then for line in p:lines() do entries[#entries + 1] = line end p:close() end
        local i = 0
        return function() i = i + 1; return entries[i] end
    end,
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
        LAST_API_AUTH = t.headers and t.headers["Authorization"]
        if THROW_ON_REPO and t.url:find(THROW_ON_REPO, 1, true) then error("injected API error") end
        PENDING_JSON = FIXTURES[t.url]
        if t.sink then t.sink("json"); t.sink(nil) end
        return 1, (PENDING_JSON and 200 or 404)
    end
    if t.url:find("codeload.github.com") then CODELOAD_HIT = true end
    if DOWNLOAD_FAIL then return 1, 500 end
    -- file download: write dummy bytes so the temp file is created
    if t.sink then t.sink("BYTES"); t.sink(nil) end
    return 1, 200
end })

preload("rapidjson", { decode = function(_) return PENDING_JSON end })

-- ffi/archiver mock: iterate returns fixture entries; extractToPath writes file.
local Archiver = { Reader = {} }
Archiver.Reader.__index = Archiver.Reader
function Archiver.Reader:new() return setmetatable({}, Archiver.Reader) end
function Archiver.Reader:open(path)
    if ARCHIVE_OPEN_FAIL then return false end
    self._path = path; self._entries = ARCHIVE_ENTRIES[path] or {}; return true
end
function Archiver.Reader:iterate()
    local i = 0
    return function() i = i + 1; return self._entries[i] end
end
function Archiver.Reader:extractToPath(_archive_path, dest_path)
    EXTRACT_ATTEMPTS = EXTRACT_ATTEMPTS + 1
    if EXTRACT_FAIL_AT and EXTRACT_ATTEMPTS == EXTRACT_FAIL_AT then return false end
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
preload("ui/widget/progressbardialog", { new = function(_, o)
    STATUS_LOG[#STATUS_LOG + 1] = { title = o and o.title, subtitle = o and o.subtitle }
    return { show = function() end, close = function() end, reportProgress = function() end }
end })
local NetworkMgr = {
    _connected = true,
    isConnected = function(self) return self._connected end,
    runWhenOnline = function(_, fn) fn() end,
    beforeWifiAction = function(_, cb) BEFORE_WIFI_CB = cb end,
}
preload("ui/network/manager", NetworkMgr)
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

print("\n== managed model (manage-if-installed) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS)
    local f = newInstance()
    local ZEN = "AnthonyGress/zen_ui.koplugin"
    local BOOK = "AndyHazz/bookends.koplugin"
    local function src(repo)
        for _, s in ipairs(f:getSources()) do if s.repo == repo then return s end end
    end

    -- Curated plugin, not installed -> NOT managed by default (won't install).
    ok("curated + not installed -> not managed", f:isSourceManaged(src(ZEN)) == false)
    ok("self -> managed by default", f:isSourceManaged(src("MatthewBriggs/fetcher.koplugin")) == true)

    -- Curated plugin, already installed -> managed by default (auto-update).
    mkdirp(PLUGINS .. "/zen_ui.koplugin")
    ok("curated + installed -> managed", f:isSourceManaged(src(ZEN)) == true)

    -- Explicit choices override the default either way.
    f:setSourceManaged(BOOK, true)
    ok("opt-in: not-installed plugin becomes managed", f:isSourceManaged(src(BOOK)) == true)
    f:setSourceManaged(ZEN, false)
    ok("opt-out: installed plugin becomes unmanaged", f:isSourceManaged(src(ZEN)) == false)
    rmrf(PLUGINS .. "/zen_ui.koplugin")
end

print("\n== migrate disabled_patch_repos -> source_enabled ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    f:saveSetting("disabled_patch_repos", { "some/repo", "other/thing.koplugin" })
    f:migrateDisabledRepos()
    local choices = f:getSetting("source_enabled", {})
    ok("old disabled repo migrated to false", choices["some/repo"] == false)
    ok("second disabled repo migrated to false", choices["other/thing.koplugin"] == false)
    ok("migration flag set", f:getSetting("source_enabled_migrated", false) == true)
    f:saveSetting("source_enabled", {})
    f:migrateDisabledRepos()
    ok("re-migrate is a no-op", next(f:getSetting("source_enabled", {})) == nil)
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
    ok("curated plugin has dir + curated flag, no files", byrepo["AnthonyGress/zen_ui.koplugin"]
        and byrepo["AnthonyGress/zen_ui.koplugin"].dir
        and byrepo["AnthonyGress/zen_ui.koplugin"].curated == true
        and byrepo["AnthonyGress/zen_ui.koplugin"].files == nil)
    ok("self is not flagged curated", byrepo["MatthewBriggs/fetcher.koplugin"].curated ~= true)
    local curated_n = 0
    for _, s in ipairs(sources) do if s.curated then curated_n = curated_n + 1 end end
    ok("curated list has 15 plugins", curated_n == 15, curated_n)
    ok("user plugin source got dir backfilled", byrepo["u/thing.koplugin"]
        and byrepo["u/thing.koplugin"].dir == PLUGINS .. "/thing.koplugin/")
    ok("user patch source has no plugin type", byrepo["u/patches"] and byrepo["u/patches"].type ~= "plugin")
end

print("\n== menu split ==")
do
    rmrf(PLUGINS); mkdirp(PLUGINS)
    local f = newInstance()
    local plugin_items = f:genPluginMenuItems()
    local patch_items = f:genSourceMenuItems()
    local function has(items, needle)
        for _, it in ipairs(items) do if it.text and it.text:find(needle, 1, true) then return true end end
        return false
    end
    ok("Plugin sources lists self", has(plugin_items, "MatthewBriggs/fetcher.koplugin"))
    ok("Plugin sources lists curated plugin", has(plugin_items, "AnthonyGress/zen_ui.koplugin"))
    ok("Plugin sources shows install status", has(plugin_items, "not installed"))
    ok("Plugin sources excludes patch repo", not has(plugin_items, "u/patches"))
    ok("Patch sources lists patch repo", has(patch_items, "u/patches"))
    ok("Patch sources excludes plugins", not has(patch_items, "MatthewBriggs/fetcher.koplugin"))
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
    STATUS_LOG = {}

    local needs_restart, plugin_line, patch_line = f:syncSources()
    local flipped = false
    for _, s in ipairs(STATUS_LOG) do
        if s.title == "Plugins" or s.title == "Patches" then flipped = true end
    end
    ok("status heading does not flip to bare Plugins/Patches", not flipped)
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

print("\n== plugins/-wrapped zip + zipball fallback ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    local f = newInstance()
    local WRAP = "test/wrapped.koplugin"    -- release .zip wrapped in plugins/<name>/
    local FALL = "test/fallback.koplugin"   -- release with NO .zip asset -> zipball
    local wrap_dir = PLUGINS .. "/wrapped.koplugin/"
    local fall_dir = PLUGINS .. "/fallback.koplugin/"
    f.getSources = function()
        return {
            { repo = WRAP, type = "plugin", dir = wrap_dir },
            { repo = FALL, type = "plugin", dir = fall_dir },
        }
    end
    local api = function(r) return "https://api.github.com/repos/" .. r .. "/releases/latest" end
    FIXTURES = {
        [api(WRAP)] = { tag_name = "v1", assets = {
            { name = "wrapped.koplugin.zip", browser_download_url = "https://dl/wrapped.zip", size = 10 } } },
        [api(FALL)] = { tag_name = "v2", assets = {} }, -- no .zip -> source-zipball fallback
    }
    ARCHIVE_ENTRIES = {
        [DATA .. "/fetcher_tmp/wrapped.koplugin.zip"] = {
            { path = "plugins/wrapped.koplugin/main.lua", mode = "file" },
            { path = "plugins/wrapped.koplugin/sub/x.lua", mode = "file" },
        },
        [DATA .. "/fetcher_tmp/fallback.koplugin.zip"] = {
            { path = "test-fallback.koplugin-abc123/main.lua", mode = "file" },
            { path = "test-fallback.koplugin-abc123/_meta.lua", mode = "file" },
        },
    }
    CODELOAD_HIT = false
    local _nr, pline = f:syncSources()
    ok("plugins/-wrapped: main.lua at dest root (2-segment strip)", exists(wrap_dir .. "main.lua"))
    ok("plugins/-wrapped: nested file preserved", exists(wrap_dir .. "sub/x.lua"))
    ok("plugins/-wrapped: no double-nesting", not exists(wrap_dir .. "plugins"))
    ok("zipball fallback: installed from source zip", exists(fall_dir .. "main.lua") and exists(fall_dir .. "_meta.lua"))
    ok("zipball fallback: used codeload URL", CODELOAD_HIT == true)
    ok("both plugins reported updated", pline == "Plugins: 2 updated ✓", pline)
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

local function resetInjection()
    ARCHIVE_OPEN_FAIL = false; EXTRACT_FAIL_AT = nil; EXTRACT_ATTEMPTS = 0
    DOWNLOAD_FAIL = false; THROW_ON_REPO = nil
end

print("\n== edge: partial extraction never corrupts a fresh install ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/broken.koplugin", PLUGINS .. "/broken.koplugin/"
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "broken.koplugin.zip", browser_download_url = "https://dl/b.zip", size = 1 } } } }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/broken.koplugin.zip"] = {
        { path = "broken.koplugin/main.lua", mode = "file" },
        { path = "broken.koplugin/lib/x.lua", mode = "file" },
        { path = "broken.koplugin/_meta.lua", mode = "file" },
    } }
    EXTRACT_FAIL_AT = 2 -- fail extracting the 2nd file
    local _nr, pline = f:syncSources()
    ok("destination NOT created on failed extraction", not exists(dir))
    ok("no files leaked to destination", not exists(dir .. "main.lua"))
    ok("staging dir cleaned up", not exists(PLUGINS .. "/broken.koplugin.fetcher-new"))
    ok("reported failed", pline == "Plugins: 0 updated, failed: broken.koplugin", pline)
    ok("installed tag NOT recorded", f:getSetting("patch_installed_tags", {})[REPO] == nil)
end

print("\n== edge: failed update keeps the old install intact ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/existing.koplugin", PLUGINS .. "/existing.koplugin/"
    mkdirp(dir); writefile(dir .. "main.lua", "OLD"); writefile(dir .. "_meta.lua", "OLDMETA")
    f:saveSetting("patch_installed_tags", { [REPO] = "v0" })
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "existing.koplugin.zip", browser_download_url = "https://dl/e.zip", size = 1 } } } }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/existing.koplugin.zip"] = {
        { path = "existing.koplugin/main.lua", mode = "file" },
        { path = "existing.koplugin/_meta.lua", mode = "file" },
    } }
    EXTRACT_FAIL_AT = 2
    local _nr, pline = f:syncSources()
    ok("old main.lua unchanged", readfile(dir .. "main.lua") == "OLD")
    ok("old _meta.lua unchanged", readfile(dir .. "_meta.lua") == "OLDMETA")
    ok("no staging/backup dirs left", not exists(PLUGINS .. "/existing.koplugin.fetcher-new")
        and not exists(PLUGINS .. "/existing.koplugin.fetcher-old"))
    ok("installed tag stays v0", f:getSetting("patch_installed_tags", {})[REPO] == "v0")
    ok("reported failed", pline == "Plugins: 0 updated, failed: existing.koplugin", pline)
end

print("\n== edge: successful update replaces atomically (stale files removed) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/upd.koplugin", PLUGINS .. "/upd.koplugin/"
    mkdirp(dir); writefile(dir .. "main.lua", "OLD"); writefile(dir .. "removed_in_v1.lua", "STALE")
    f:saveSetting("patch_installed_tags", { [REPO] = "v0" })
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "upd.koplugin.zip", browser_download_url = "https://dl/u.zip", size = 1 } } } }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/upd.koplugin.zip"] = { { path = "upd.koplugin/main.lua", mode = "file" } } }
    local _nr, pline = f:syncSources()
    ok("main.lua replaced with new content", readfile(dir .. "main.lua") == "extracted")
    ok("stale file removed by whole-dir swap", not exists(dir .. "removed_in_v1.lua"))
    ok("no backup/staging left", not exists(PLUGINS .. "/upd.koplugin.fetcher-old")
        and not exists(PLUGINS .. "/upd.koplugin.fetcher-new"))
    ok("tag bumped to v1", f:getSetting("patch_installed_tags", {})[REPO] == "v1")
    ok("reported 1 updated", pline == "Plugins: 1 updated ✓", pline)
end

print("\n== edge: corrupt zip and download failure ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/corrupt.koplugin", PLUGINS .. "/corrupt.koplugin/"
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "corrupt.koplugin.zip", browser_download_url = "https://dl/c.zip", size = 1 } } } }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/corrupt.koplugin.zip"] = { { path = "corrupt.koplugin/main.lua", mode = "file" } } }

    ARCHIVE_OPEN_FAIL = true
    local _n1, p1 = f:syncSources()
    ok("corrupt zip: failed, nothing installed", not exists(dir) and p1 == "Plugins: 0 updated, failed: corrupt.koplugin", p1)
    ok("corrupt zip: temp zip cleaned up", not exists(DATA .. "/fetcher_tmp/corrupt.koplugin.zip"))
    ok("corrupt zip: tag not recorded", f:getSetting("patch_installed_tags", {})[REPO] == nil)

    ARCHIVE_OPEN_FAIL = false; DOWNLOAD_FAIL = true
    local _n2, p2 = f:syncSources()
    ok("download 500: failed, nothing installed", not exists(dir) and p2 == "Plugins: 0 updated, failed: corrupt.koplugin", p2)
    ok("download 500: temp zip cleaned up", not exists(DATA .. "/fetcher_tmp/corrupt.koplugin.zip"))
    DOWNLOAD_FAIL = false
end

print("\n== edge: one failing source does not abort the others ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local BAD, GOOD = "throwy/bad.koplugin", "okay/good.koplugin"
    local good_dir = PLUGINS .. "/good.koplugin/"
    f.getSources = function() return {
        { repo = BAD, type = "plugin", dir = PLUGINS .. "/bad.koplugin/" },
        { repo = GOOD, type = "plugin", dir = good_dir },
    } end
    FIXTURES = {
        ["https://api.github.com/repos/" .. BAD .. "/releases/latest"] = { tag_name = "v1", assets = {} },
        ["https://api.github.com/repos/" .. GOOD .. "/releases/latest"] = { tag_name = "v1",
            assets = { { name = "good.koplugin.zip", browser_download_url = "https://dl/g.zip", size = 1 } } },
    }
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/good.koplugin.zip"] = { { path = "good.koplugin/main.lua", mode = "file" } } }
    THROW_ON_REPO = BAD -- BAD's API fetch throws -> should be caught per-source
    local _nr, pline = f:syncSources()
    ok("throwing source reported as failed", pline:find("bad.koplugin", 1, true) ~= nil, pline)
    ok("later good source still installed", exists(good_dir .. "main.lua"))
    ok("good update still counted", pline:find("1 updated", 1, true) ~= nil, pline)
    THROW_ON_REPO = nil
end

print("\n== version: semantic compare from installed _meta (no downgrade) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/ver.koplugin", PLUGINS .. "/ver.koplugin/"
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/ver.koplugin.zip"] = {
        { path = "ver.koplugin/main.lua", mode = "file" }, { path = "ver.koplugin/_meta.lua", mode = "file" } } }
    local function installedAs(ver) rmrf(dir); mkdirp(dir); writefile(dir .. "main.lua", "x")
        writefile(dir .. "_meta.lua", 'return { version = "' .. ver .. '" }') end
    local function releaseIs(tag) FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = tag, assets = { { name = "ver.koplugin.zip", browser_download_url = "https://dl/v.zip", size = 1 } } } } end

    installedAs("1.2.0"); releaseIs("v1.2.0")
    local _a, pa = f:syncSources()
    ok("same version -> no update", pa == "Plugins: up to date ✓", pa)

    installedAs("1.2.0"); releaseIs("v1.10.0")
    local _b, pb = f:syncSources()
    ok("newer version (1.10 > 1.2) -> update", pb == "Plugins: 1 updated ✓", pb)

    installedAs("0.20.1-dev"); releaseIs("v0.20.0")
    local _c, pc = f:syncSources()
    ok("release older than installed -dev -> NO downgrade", pc == "Plugins: up to date ✓", pc)
end

print("\n== version: versionless plugin falls back to stored tag ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/notag.koplugin", PLUGINS .. "/notag.koplugin/"
    mkdirp(dir); writefile(dir .. "main.lua", "x") -- installed, no readable _meta version
    f:saveSetting("patch_installed_tags", { [REPO] = "v1" })
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir } } end
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/notag.koplugin.zip"] = { { path = "notag.koplugin/main.lua", mode = "file" } } }
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v1", assets = { { name = "notag.koplugin.zip", browser_download_url = "https://dl/n.zip", size = 1 } } } }
    local _a, pa = f:syncSources()
    ok("versionless + same tag -> no update (tag fallback)", pa == "Plugins: up to date ✓", pa)
    FIXTURES["https://api.github.com/repos/" .. REPO .. "/releases/latest"].tag_name = "v2"
    local _b, pb = f:syncSources()
    ok("versionless + newer tag -> update (tag fallback)", pb == "Plugins: 1 updated ✓", pb)
end

print("\n== token: Authorization header when token file present ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    writefile(SETTINGS .. "/fetcher_github_token.txt", "  ghp_TESTTOKEN  \n")
    local f = newInstance()
    local REPO = "test/tok.koplugin"
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = PLUGINS .. "/tok.koplugin/" } } end
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] = { tag_name = "v1", assets = {} } }
    LAST_API_AUTH = nil
    f:syncSources()
    ok("token injected + whitespace-trimmed", LAST_API_AUTH == "token ghp_TESTTOKEN", tostring(LAST_API_AUTH))

    -- and absent when no token file
    os.remove(SETTINGS .. "/fetcher_github_token.txt")
    local f2 = newInstance()
    f2.getSources = function() return { { repo = REPO, type = "plugin", dir = PLUGINS .. "/tok.koplugin/" } } end
    LAST_API_AUTH = "sentinel"
    f2:syncSources()
    ok("no token file -> no Authorization header", LAST_API_AUTH == nil)
end

print("\n== keep_files: user config survives an update ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS); rmrf(PLUGINS); mkdirp(PLUGINS); rmrf(DATA); mkdirp(DATA)
    resetInjection()
    local f = newInstance()
    local REPO, dir = "test/cfg.koplugin", PLUGINS .. "/cfg.koplugin/"
    f.getSources = function() return { { repo = REPO, type = "plugin", dir = dir,
        keep_files = { "config.lua", "keys/api.txt" } } } end
    mkdirp(dir); writefile(dir .. "main.lua", "OLD"); writefile(dir .. "_meta.lua", 'return { version = "1.0.0" }')
    writefile(dir .. "config.lua", "USERCONFIG"); mkdirp(dir .. "keys"); writefile(dir .. "keys/api.txt", "SECRET")
    -- new release ships only main.lua + _meta.lua (not the user files)
    ARCHIVE_ENTRIES = { [DATA .. "/fetcher_tmp/cfg.koplugin.zip"] = {
        { path = "cfg.koplugin/main.lua", mode = "file" }, { path = "cfg.koplugin/_meta.lua", mode = "file" } } }
    FIXTURES = { ["https://api.github.com/repos/" .. REPO .. "/releases/latest"] =
        { tag_name = "v2.0.0", assets = { { name = "cfg.koplugin.zip", browser_download_url = "https://dl/c.zip", size = 1 } } } }
    local _n, p = f:syncSources()
    ok("update applied", p == "Plugins: 1 updated ✓", p)
    ok("main.lua replaced with new content", readfile(dir .. "main.lua") == "extracted")
    ok("preserved config.lua survived", readfile(dir .. "config.lua") == "USERCONFIG")
    ok("preserved nested keys/api.txt survived", readfile(dir .. "keys/api.txt") == "SECRET")
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

print("\n== wifi gate ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    f:saveSetting("enable_koreader_update", false)
    f:saveSetting("enable_opds_sync", false)
    f.getSources = function() return {} end

    -- Offline: sync body must NOT run; connect flow invoked with a retry cb.
    NetworkMgr._connected = false
    BEFORE_WIFI_CB = nil
    ui_shown = {}
    STATUS_LOG = {}
    f:runSync()
    ok("offline: sync body does not run", #ui_shown == 0 and #STATUS_LOG == 0)
    ok("offline: connect flow invoked with retry callback", type(BEFORE_WIFI_CB) == "function")

    -- Wi-Fi comes up, retry callback fires -> body runs (bar gets created).
    NetworkMgr._connected = true
    STATUS_LOG = {}
    BEFORE_WIFI_CB()
    ok("after connect: sync body runs", #STATUS_LOG >= 1)
end

print("\n== version display: reads live from _meta.lua next to main.lua ==")
do
    local f = newInstance()
    -- Drop a _meta.lua in the fake plugin dir the harness points getSelfDir at.
    mkdirp(PLUGINS .. "/fetcher.koplugin")
    writefile(PLUGINS .. "/fetcher.koplugin/_meta.lua",
        'return { name = "fetcher", version = "9.8.7" }')
    ok("getSelfVersion reads the installed _meta.lua", f:getSelfVersion() == "9.8.7")
    -- Falls back gracefully when the file is missing.
    f.getSelfDir = function() return WORK .. "/no-such-plugin-dir/" end
    ok("getSelfVersion falls back to 'unknown' when meta is missing",
        f:getSelfVersion() == "unknown")
end

print("\n== runSync smoke (update+opds disabled) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    f:saveSetting("enable_koreader_update", false)
    f:saveSetting("enable_opds_sync", false)
    f.getSources = function() return {} end
    NetworkMgr._connected = true
    ui_shown = {}
    local good, err = pcall(function() f:runSync() end)
    ok("runSync completes without error", good, err)
    ok("runSync shows a summary widget", #ui_shown >= 1)
end

print("\n== runSync recovers cleanly when _doSync errors (no stuck modal) ==")
do
    rmrf(SETTINGS); mkdirp(SETTINGS)
    local f = newInstance()
    f._doSync = function() error("boom") end
    NetworkMgr._connected = true
    ui_shown = {}
    local good = pcall(function() f:runSync() end)
    ok("runSync survives an error in _doSync", good)
    ok("error path shows an error dialog", #ui_shown >= 1)
end

print(string.format("\n==== %d passed, %d failed ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
