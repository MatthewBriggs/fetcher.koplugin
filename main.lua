local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local OTAManager = require("ui/otamanager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SELF_REPO = "MatthewBriggs/fetcher.koplugin"
local SELF_FILES = { "main.lua", "_meta.lua" }

-- Curated built-in plugin sources: popular KOReader plugins distributed as a
-- single release .zip (or a release whose source zipball we fall back to).
-- They are *offered*, not forced: one that is already installed is kept
-- updated; one that isn't is shown in "Plugin sources…" but only installed if
-- the user ticks it (see isSourceManaged / syncSources).
-- `keep_files` lists user-created files (relative to the plugin dir) to carry
-- across updates so a refresh doesn't wipe API keys / configuration.
local CURATED_PLUGINS = {
    { repo = "AnthonyGress/zen_ui.koplugin" },
    { repo = "AndyHazz/bookends.koplugin" },
    { repo = "AndyHazz/bookshelf.koplugin" },
    { repo = "Euphoriyy/appearance.koplugin" },
    { repo = "doctorhetfield-cmd/simpleui.koplugin" },
    { repo = "omer-faruq/appstore.koplugin",
      keep_files = { "appstore_configuration.lua" } },
    { repo = "ZlibraryKO/zlibrary.koplugin" },
    { repo = "pengcw/legado.koplugin" },
    { repo = "greywolf1499/opds_plus.koplugin" },
    { repo = "zeeyado/koassistant.koplugin",
      keep_files = { "apikeys.lua", "configuration.lua", "custom_actions.lua", "behaviors", "domains" } },
    { repo = "dani84bs/AnnotationSync.koplugin" },
    { repo = "iceyear/readeck.koplugin" },
    { repo = "kristianpennacchia/zzz-readermenuredesign.koplugin" },
    { repo = "gitalexcampos/highlightsync.koplugin" },
    { repo = "ura23/batterygraph.koplugin" },
}

-- Split a version string into a list of numeric components. A leading "v" is
-- dropped; components are separated by "." or "-"; anything non-numeric (a
-- git-sha or "-dev" build suffix) becomes 0. A trailing sentinel makes the
-- final component fall out of the same loop.
local function versionComponents(v)
    v = tostring(v):gsub("^%s*[vV]", "")
    local out = {}
    for token in (v .. "."):gmatch("(.-)[%.%-]") do
        out[#out + 1] = tonumber(token) or 0
    end
    return out
end

-- Three-way version compare: 1 if `a` outranks `b`, -1 if it trails, 0 equal.
-- Missing trailing components read as 0 ("1.0" == "1.0.0"), and larger numbers
-- win componentwise ("1.10" > "1.2").
local function compareVersions(a, b)
    local ca, cb = versionComponents(a), versionComponents(b)
    for i = 1, math.max(#ca, #cb) do
        local diff = (ca[i] or 0) - (cb[i] or 0)
        if diff ~= 0 then
            return diff > 0 and 1 or -1
        end
    end
    return 0
end

-- True only when `a` is strictly newer than `b`; used so an update never
-- reinstalls the same version or downgrades a newer build (e.g. a local
-- "0.20.1-dev" is not replaced by release "0.20.0").
local function isVersionNewer(a, b)
    if not a or not b then return false end
    return compareVersions(a, b) == 1
end

local Fetcher = WidgetContainer:extend{
    name = "fetcher",
    settings_file = DataStorage:getSettingsDir() .. "/fetcher.lua",
    settings = nil,
}

-- Settings ------------------------------------------------------------------

function Fetcher:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
end

function Fetcher:getSetting(key, default)
    self:loadSettings()
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function Fetcher:saveSetting(key, value)
    self:loadSettings()
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- A plugin source is "installed" if its destination directory exists.
function Fetcher:isPluginInstalled(source)
    if not source.dir then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes((source.dir:gsub("/+$", ""))) ~= nil
end

-- The version an installed plugin reports in its own _meta.lua, or nil if it
-- isn't installed or doesn't declare a readable version. This is the source of
-- truth for "do we need an update", so the decision self-corrects from what's
-- actually on disk instead of a settings map that can drift.
function Fetcher:installedPluginVersion(source)
    if not source.dir then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local meta = source.dir:gsub("/+$", "") .. "/_meta.lua"
    if lfs.attributes(meta, "mode") ~= "file" then return nil end
    local ok, data = pcall(dofile, meta)
    if ok and type(data) == "table" and data.version ~= nil then
        return tostring(data.version)
    end
    return nil
end

-- Read Fetcher's own version from the installed _meta.lua next to main.lua.
-- Reading it at runtime (rather than hardcoding a constant) means a self-
-- update automatically flows through to the settings display without
-- needing to remember to bump two places in sync.
function Fetcher:getSelfVersion()
    local path = self:getSelfDir() .. "_meta.lua"
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" and data.version then
        return tostring(data.version)
    end
    return "unknown"
end

-- Optional GitHub personal-access token, read once from a plain-text file the
-- user drops in the settings dir (settings/fetcher_github_token.txt). Raises
-- the GitHub API rate limit from 60 to 5000 requests/hour. Empty when absent.
function Fetcher:getGitHubToken()
    if self._gh_token_checked then return self._gh_token end
    self._gh_token_checked = true
    self._gh_token = nil
    local path = DataStorage:getSettingsDir() .. "/fetcher_github_token.txt"
    local f = io.open(path, "r")
    if f then
        local token = (f:read("*a") or ""):gsub("%s+", "")
        f:close()
        if token ~= "" then self._gh_token = token end
    end
    return self._gh_token
end

-- Whether a source is managed (installed/updated on sync). Explicit user
-- choices (the source_enabled map) always win; otherwise a sensible default
-- per source: a curated plugin is managed only if it's *already installed*
-- (so a fresh install never pulls in plugins the user didn't ask for),
-- while everything else — Fetcher itself, user-listed sources, patch repos —
-- is managed by default.
function Fetcher:isSourceManaged(source)
    local choices = self:getSetting("source_enabled", {})
    local v = choices[source.repo]
    if v ~= nil then return v end
    if source.curated then
        return self:isPluginInstalled(source)
    end
    return true
end

function Fetcher:setSourceManaged(repo, enabled)
    local choices = self:getSetting("source_enabled", {})
    choices[repo] = enabled
    self:saveSetting("source_enabled", choices)
end

-- One-time migration of the old opt-out list (disabled_patch_repos) to the
-- explicit-choice map (source_enabled), so prior "don't touch this" choices
-- carry over.
function Fetcher:migrateDisabledRepos()
    if self:getSetting("source_enabled_migrated", false) then return end
    local disabled = self:getSetting("disabled_patch_repos", nil)
    if type(disabled) == "table" then
        local choices = self:getSetting("source_enabled", {})
        for _, repo in ipairs(disabled) do
            if choices[repo] == nil then choices[repo] = false end
        end
        self:saveSetting("source_enabled", choices)
    end
    self:saveSetting("source_enabled_migrated", true)
end

-- One-time migration for the ReaderSync → Fetcher rename: the old settings
-- files (readersync.lua = disabled repos / installed tags / catalog picks,
-- readersync_sources.lua = user-configured patch sources) are orphaned once
-- the code starts reading fetcher.lua / fetcher_sources.lua. Copy them over
-- if the new files don't exist yet, so nothing the user configured is lost.
function Fetcher:migrateLegacySettings()
    local lfs = require("libs/libkoreader-lfs")
    local dir = DataStorage:getSettingsDir()
    local pairs_to_migrate = {
        { old = dir .. "/readersync.lua",         new = dir .. "/fetcher.lua" },
        { old = dir .. "/readersync_sources.lua", new = dir .. "/fetcher_sources.lua" },
    }
    for _, m in ipairs(pairs_to_migrate) do
        if not lfs.attributes(m.new) and lfs.attributes(m.old) then
            local inf = io.open(m.old, "r")
            if inf then
                local content = inf:read("*a")
                inf:close()
                local outf = io.open(m.new, "w")
                if outf then
                    outf:write(content)
                    outf:close()
                end
            end
        end
    end
end

-- OPDS catalog list ---------------------------------------------------------

function Fetcher:getOPDSServers()
    local opds_file = DataStorage:getSettingsDir() .. "/opds.lua"
    local opds_settings = LuaSettings:open(opds_file)
    return opds_settings:readSetting("servers", {})
end

function Fetcher:genCatalogMenuItems()
    local servers = self:getOPDSServers()
    if #servers == 0 then
        return {{
            text = _("No OPDS catalogs configured"),
            enabled = false,
        }}
    end

    local items = {}
    for _, server in ipairs(servers) do
        local url = server.url
        local title = server.title or url
        items[#items + 1] = {
            text = title,
            checked_func = function()
                local urls = self:getSetting("opds_catalog_urls", {})
                for _, u in ipairs(urls) do
                    if u == url then return true end
                end
                return false
            end,
            callback = function()
                local urls = self:getSetting("opds_catalog_urls", {})
                local found = false
                for i, u in ipairs(urls) do
                    if u == url then
                        table.remove(urls, i)
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(urls, url)
                end
                self:saveSetting("opds_catalog_urls", urls)
            end,
        }
    end
    return items
end

-- OPDS sync -----------------------------------------------------------------

function Fetcher:syncOPDS()
    local catalog_urls = self:getSetting("opds_catalog_urls", {})
    if #catalog_urls == 0 then
        return false, _("No catalogs selected for sync. Configure in Fetcher settings.")
    end

    local opds_file = DataStorage:getSettingsDir() .. "/opds.lua"
    local opds_settings_store = LuaSettings:open(opds_file)
    local opds_settings = opds_settings_store:readSetting("settings", {})
    local servers = opds_settings_store:readSetting("servers", {})
    local downloads = opds_settings_store:readSetting("downloads", {})

    if not opds_settings.sync_dir then
        return false, _("OPDS sync folder not set. Configure it in the OPDS Catalog plugin (Sync > Set sync folder).")
    end

    local selected_map = {}
    for _, url in ipairs(catalog_urls) do
        selected_map[url] = true
    end
    local sync_servers = {}
    for _, server in ipairs(servers) do
        if selected_map[server.url] then
            local s = {}
            for k, v in pairs(server) do s[k] = v end
            s.sync = true
            table.insert(sync_servers, s)
        end
    end

    if #sync_servers == 0 then
        return false, _("Selected catalogs not found in OPDS settings.")
    end

    local lfs = require("libs/libkoreader-lfs")
    local OPDSBrowser = require("opdsbrowser")
    local T = require("ffi/util").template

    local force = self:getSetting("opds_force_resync", false)
    local browser = OPDSBrowser:new{
        settings = opds_settings,
        servers = sync_servers,
        downloads = downloads,
        pending_syncs = {},
        _manager = { updated = false },
        sync = true,
        sync_force = force,
        sync_server_list = {},
    }

    for _, server in ipairs(sync_servers) do
        browser:fillPendingSyncs(server)
    end

    local pending = browser.pending_syncs
    if #pending == 0 then
        return true, _("Books: up to date ✓")
    end

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ProgressbarDialog = require("ui/widget/progressbardialog")

    local downloaded_urls = self:getSetting("downloaded_urls", {})

    local dl_count = 0
    for i, item in ipairs(pending) do
        local filename = item.file:match("([^/]+)$") or item.file

        if not force and downloaded_urls[item.url] then
            -- already downloaded in a previous sync, skip regardless of filename
        elseif not lfs.attributes(item.file) then
            socketutil:set_timeout()
            local _body, _code, headers = http.request{
                method = "HEAD",
                url = item.url,
                user = item.username,
                password = item.password,
                sink = ltn12.sink.null(),
                headers = { ["Accept-Encoding"] = "identity" },
            }
            socketutil:reset_timeout()
            local total_bytes = (type(headers) == "table") and tonumber(headers["content-length"]) or nil

            local progress_dialog = ProgressbarDialog:new{
                title = T(_("Downloading %1 of %2"), i, #pending),
                subtitle = filename,
                progress_max = total_bytes,
                refresh_time_seconds = 1,
            }
            self:closeStatus()
            progress_dialog:show()
            UIManager:forceRePaint()

            local file_sink = ltn12.sink.file(io.open(item.file, "w"))
            local progress_sink = socketutil.chainSinkWithProgressCallback(file_sink, function(bytes)
                progress_dialog:reportProgress(bytes)
            end)

            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local dl_code = socket.skip(1, http.request{
                url = item.url,
                headers = { ["Accept-Encoding"] = "identity" },
                sink = progress_sink,
                user = item.username,
                password = item.password,
            })
            socketutil:reset_timeout()
            progress_dialog:close()

            if dl_code == 200 then
                dl_count = dl_count + 1
                downloaded_urls[item.url] = true
                self:saveSetting("downloaded_urls", downloaded_urls)
            else
                os.remove(item.file)
            end
        end
    end

    for _, synced in ipairs(sync_servers) do
        for _, server in ipairs(servers) do
            if server.url == synced.url then
                server.last_download = synced.last_download
            end
        end
    end
    opds_settings_store:saveSetting("servers", servers)
    opds_settings_store:flush()

    self:saveSetting("opds_force_resync", false)
    return true, T(_("Books: %1 downloaded ✓"), dl_count)
end

-- Patch sync ----------------------------------------------------------------

function Fetcher:genPatchMenuItems()
    -- Only show patches from configured repos (known_patches cache populated by sync)
    local known_set = {}
    local known_patches = self:getSetting("known_patches", {})
    for _i, repo_names in pairs(known_patches) do
        for _j, name in ipairs(repo_names) do
            known_set[name] = true
        end
    end

    local items = {}
    for filename in pairs(known_set) do
        items[#items + 1] = {
            text = filename,
            checked_func = function()
                local disabled = self:getSetting("disabled_patches", {})
                for _i, f in ipairs(disabled) do
                    if f == filename then return false end
                end
                return true
            end,
            callback = function()
                local disabled = self:getSetting("disabled_patches", {})
                local found = false
                for i, f in ipairs(disabled) do
                    if f == filename then
                        table.remove(disabled, i)
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(disabled, filename)
                end
                self:saveSetting("disabled_patches", disabled)
            end,
        }
    end

    if #items == 0 then
        return {{ text = _("No patches known yet — run a sync first"), enabled = false }}
    end
    table.sort(items, function(a, b) return a.text < b.text end)
    return items
end


-- Build a toggle menu item for a single source. The tick reflects whether the
-- source is managed (installed/updated on sync); toggling records an explicit
-- choice in the source_enabled map. Ticking a not-yet-installed plugin opts in
-- to installing it on the next sync.
function Fetcher:genRepoToggleItem(source, text)
    local repo = source.repo
    return {
        text = text or repo,
        checked_func = function() return self:isSourceManaged(source) end,
        callback = function()
            self:setSourceManaged(repo, not self:isSourceManaged(source))
        end,
    }
end

-- Plugin sources: whole plugins (type == "plugin") — Fetcher itself, the
-- curated built-ins, and any user-listed plugin repos. Each shows whether it
-- is currently installed.
function Fetcher:genPluginMenuItems()
    local items = {}
    for _i, source in ipairs(self:getSources()) do
        if source.repo and source.type == "plugin" then
            local status = self:isPluginInstalled(source) and _("installed") or _("not installed")
            items[#items + 1] = self:genRepoToggleItem(source, source.repo .. "  (" .. status .. ")")
        end
    end
    if #items == 0 then
        return {{ text = _("No plugin sources configured"), enabled = false }}
    end
    return items
end

-- Patch sources: repos whose releases ship individual .lua patch files
-- (the legacy, user-configured sources — not whole plugins).
function Fetcher:genSourceMenuItems()
    local items = {}
    for _i, source in ipairs(self:getSources()) do
        if source.repo and source.type ~= "plugin" then
            items[#items + 1] = self:genRepoToggleItem(source)
        end
    end
    if #items == 0 then
        return {{
            text = _("No sources configured — edit settings/fetcher_sources.lua"),
            enabled = false,
        }}
    end
    return items
end

function Fetcher:getSources()
    local lfs = require("libs/libkoreader-lfs")
    local sources_file = DataStorage:getSettingsDir() .. "/fetcher_sources.lua"
    local sources = {}
    if lfs.attributes(sources_file) then
        local ok, file_sources = pcall(dofile, sources_file)
        if ok and type(file_sources) == "table" then
            sources = file_sources
        end
    end
    -- Built-ins always come first, fixed order: Fetcher itself, then the
    -- curated plugins, then user-configured sources. Plugin sources
    -- (type == "plugin") are toggled in "Plugin sources…"; patch sources in
    -- "Patch sources…".
    local plugins_parent_dir = self:getPluginsParentDir()
    local built_ins = {
        { repo = SELF_REPO, type = "plugin", dir = self:getSelfDir(), files = SELF_FILES },
    }
    for _, entry in ipairs(CURATED_PLUGINS) do
        local repo = entry.repo
        table.insert(built_ins, {
            repo = repo,
            type = "plugin",
            curated = true, -- managed only if already installed (unless opted in)
            dir = plugins_parent_dir .. repo:match("[^/]+$") .. "/",
            keep_files = entry.keep_files,
            -- no `files` field: that absence routes this source through the
            -- zip-extraction branch in syncSources() instead of the
            -- fixed-file-list branch self uses.
        })
    end
    for i = #built_ins, 1, -1 do
        table.insert(sources, 1, built_ins[i])
    end

    -- Backfill a destination dir for user-configured plugin sources that
    -- didn't specify one, so `{ repo = "u/x.koplugin", type = "plugin" }`
    -- installs to plugins/<basename>/ just like the built-ins.
    for _, source in ipairs(sources) do
        if source.repo and source.type == "plugin" and not source.dir then
            source.dir = plugins_parent_dir .. (source.repo:match("[^/]+$") or source.repo) .. "/"
        end
    end
    return sources
end

-- Sync all sources: plugins (whole-plugin updates, incl. Fetcher itself) and
-- patches (individual .lua files). Returns needs_restart plus two summary
-- lines so the caller can report plugins and patches separately.
function Fetcher:syncSources()
    local T = require("ffi/util").template
    local sources = self:getSources()

    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local json = require("rapidjson")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local lfs = require("libs/libkoreader-lfs")
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local util = require("util")
    local Archiver = require("ffi/archiver")

    local patches_dir = DataStorage:getDataDir() .. "/patches"
    if not lfs.attributes(patches_dir) then
        lfs.mkdir(patches_dir)
    end

    local fetcher_tmp_dir = DataStorage:getDataDir() .. "/fetcher_tmp"
    if not lfs.attributes(fetcher_tmp_dir) then
        lfs.mkdir(fetcher_tmp_dir)
    end

    local gh_token = self:getGitHubToken()

    -- Space out GitHub API calls a little to stay clear of secondary
    -- (abuse-detection) rate limits when checking many repos in a row.
    local last_api_ts = 0
    local function rateLimit()
        local now = socket.gettime and socket.gettime() or os.time()
        local wait = 0.15 - (now - last_api_ts)
        if wait > 0 and socket.sleep then socket.sleep(wait) end
        last_api_ts = socket.gettime and socket.gettime() or os.time()
    end

    -- Rate-limit shared across all githubGet calls in this sync. Once we hit
    -- 403 with X-RateLimit-Remaining: 0, no further API calls will succeed
    -- until the reset time — so short-circuit them (returning nil) instead of
    -- making dozens of doomed requests. Reset epoch is exposed via the outer
    -- self so the summary can render a meaningful warning.
    self._rate_limited_until = nil

    local function githubGet(url)
        if self._rate_limited_until then return nil end
        rateLimit()
        local headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "Fetcher-KOReader",
        }
        if gh_token then headers["Authorization"] = "token " .. gh_token end
        local chunks = {}
        socketutil:set_timeout()
        local _body, code, resp_headers = https.request{
            url = url,
            headers = headers,
            sink = ltn12.sink.table(chunks),
        }
        socketutil:reset_timeout()
        -- Detect GitHub rate limiting. GitHub returns 403 with
        -- X-RateLimit-Remaining: 0 (and the reset epoch in X-RateLimit-Reset).
        if code == 403 and type(resp_headers) == "table" then
            local remaining = tonumber(resp_headers["x-ratelimit-remaining"])
            local reset = tonumber(resp_headers["x-ratelimit-reset"])
            if remaining == 0 and reset then
                self._rate_limited_until = reset
            end
        end
        if code ~= 200 then return nil end
        local ok, data = pcall(json.decode, table.concat(chunks))
        return ok and data or nil
    end

    local function resolveRedirect(url)
        local current = url
        for _i = 1, 5 do
            socketutil:set_timeout()
            local _resp, code, resp_headers = https.request{
                url = current,
                method = "HEAD",
                headers = { ["User-Agent"] = "Fetcher-KOReader" },
                sink = ltn12.sink.null(),
            }
            socketutil:reset_timeout()
            if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                local loc = resp_headers and resp_headers.location
                if not loc then break end
                current = loc
            else
                break
            end
        end
        return current
    end

    local function findZipAsset(assets)
        for _, asset in ipairs(assets or {}) do
            if asset.name:match("%.zip$") then
                return asset
            end
        end
    end

    local function hasDotDotSegment(path)
        for seg in path:gmatch("[^/]+") do
            if seg == ".." then return true end
        end
        return false
    end

    local function collectZipFilePaths(reader)
        local paths = {}
        for entry in reader:iterate() do
            if entry.mode == "file" then
                table.insert(paths, entry.path)
            end
        end
        return paths
    end

    local function splitSegments(path)
        local segs = {}
        for s in path:gmatch("[^/]+") do segs[#segs + 1] = s end
        return segs
    end

    -- Longest directory path shared by every file entry, so the wrapping
    -- folder is stripped no matter how deep it is. Handles all the layouts
    -- real plugin zips use: "zen_ui.koplugin/main.lua" (strip 1),
    -- "plugins/legado.koplugin/main.lua" (strip 2), a source zipball's
    -- "owner-repo-sha/main.lua" (strip 1), or flat files (strip 0 -> nil).
    -- Only leading *directory* segments count — a file's own name never does,
    -- so a stray top-level file collapses the shared prefix to nothing.
    local function detectZipRootPrefix(paths)
        local common = splitSegments(paths[1])
        common[#common] = nil -- drop the filename component of the first path
        for i = 2, #paths do
            local segs = splitSegments(paths[i])
            local maxlen = math.min(#common, #segs - 1) -- never include path i's filename
            local k = 0
            while k < maxlen and segs[k + 1] == common[k + 1] do k = k + 1 end
            for j = #common, k + 1, -1 do common[j] = nil end
        end
        if #common == 0 then return nil end
        return table.concat(common, "/")
    end

    -- Extract every file in an open Archiver.Reader into dest_dir (created as
    -- needed). Auto-strips a common root prefix if present. All-or-nothing:
    -- any unsafe or failed entry aborts the whole extraction (matches the
    -- self-update branch's semantics — a partial failure is retried whole
    -- next sync, not left half-applied).
    local function extractZip(reader, dest_dir)
        local paths = collectZipFilePaths(reader)
        if #paths == 0 then return false end
        local prefix = detectZipRootPrefix(paths)
        for _, path in ipairs(paths) do
            local rel = path
            if prefix then
                local head = rel:sub(1, #prefix + 1)
                if head == prefix .. "/" then
                    rel = rel:sub(#prefix + 2)
                else
                    rel = nil -- stray entry outside the shared root
                end
            end
            if not rel or rel == "" or rel:sub(1, 1) == "/" or hasDotDotSegment(rel) then
                return false -- zip-slip guard / unexpected layout: reject whole archive
            end
            local dest_path = dest_dir .. rel
            local parent_dir = dest_path:match("^(.*)/")
            if parent_dir then util.makePath(parent_dir) end
            if not reader:extractToPath(path, dest_path) then
                return false
            end
        end
        return true
    end

    -- Recursively delete a file or directory tree (KOReader's util.removePath
    -- only prunes empty dirs). Missing paths are a no-op.
    local function removeTree(path)
        local mode = lfs.attributes(path, "mode")
        if mode == nil then return end
        if mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    removeTree(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    local function copyFile(src, dst)
        local inf = io.open(src, "rb")
        if not inf then return false end
        local data = inf:read("*a"); inf:close()
        local parent = dst:match("^(.*)/")
        if parent then util.makePath(parent) end
        local outf = io.open(dst, "wb")
        if not outf then return false end
        outf:write(data); outf:close()
        return true
    end

    -- Carry user-created files (API keys, config) from the current install
    -- into the freshly-extracted staging dir, so an update doesn't wipe them.
    local function keepUserFiles(source, stage)
        if not source.keep_files then return end
        local live = source.dir:gsub("/+$", "")
        for _, rel in ipairs(source.keep_files) do
            rel = tostring(rel):gsub("^[/\\]+", "")
            if rel ~= "" and lfs.attributes(live .. "/" .. rel, "mode") == "file" then
                copyFile(live .. "/" .. rel, stage .. "/" .. rel)
            end
        end
    end

    -- Move a freshly-extracted staging dir onto the real plugin dir using
    -- atomic renames, so the live install is never left half-written. Returns
    -- true on success; on failure the previous install is restored untouched.
    local function swapIntoPlace(stage, dest)
        if lfs.attributes(dest, "mode") == nil then
            return os.rename(stage, dest) and true or false -- fresh install
        end
        local old = dest .. ".fetcher-old"
        removeTree(old)
        if not os.rename(dest, old) then return false end
        if not os.rename(stage, dest) then
            os.rename(old, dest) -- put the previous install back
            return false
        end
        removeTree(old)
        return true
    end

    local installed_tags = self:getSetting("patch_installed_tags", {})
    local disabled_patches = self:getSetting("disabled_patches", {})
    local disabled_patch_set = {}
    for _i, f in ipairs(disabled_patches) do disabled_patch_set[f] = true end

    -- Plugins and patches are counted and reported separately (they are
    -- different things, even though both are updated from GitHub releases).
    local plugin_updated, plugin_failed = 0, {}
    local patch_updated, patch_failed = 0, {}

    for _i, source in ipairs(sources) do
        local repo = source.repo
        if repo and self:isSourceManaged(source) then
            local repo_short = repo:match("[^/]+$") or repo
            local is_plugin = source.type == "plugin"
            -- Isolate each source: an unexpected error (truncated write, bad
            -- archive, disk full…) fails just this source rather than aborting
            -- the whole sync. Expected failures still push onto *_failed below.
            local ok_iter = pcall(function()
            self:showStatus(_("Plugins & patches"), T(_("Checking %1…"), repo_short))

            local release = githubGet("https://api.github.com/repos/" .. repo .. "/releases/latest")

            -- Prefer the installed plugin's own _meta.lua version (self-
            -- correcting, avoids downgrades); fall back to the last-installed
            -- tag only for plugins that declare no readable version.
            local plugin_needs_update = false
            if release and release.tag_name and is_plugin then
                local installed_ver = self:installedPluginVersion(source)
                if installed_ver ~= nil then
                    plugin_needs_update = isVersionNewer(release.tag_name:gsub("^v", ""), installed_ver)
                elseif self:isPluginInstalled(source) then
                    plugin_needs_update = release.tag_name ~= installed_tags[repo]
                else
                    plugin_needs_update = true
                end
            end

            if not release or not release.tag_name then
                table.insert(is_plugin and plugin_failed or patch_failed, repo_short)
            elseif is_plugin and source.files and plugin_needs_update then
                local downloaded = {}
                for _k, filename in ipairs(source.files) do
                    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. release.tag_name .. "/" .. filename
                    local dest = source.dir .. filename .. ".new"

                    local hdrs = { ["User-Agent"] = "Fetcher-KOReader", ["Accept-Encoding"] = "identity" }
                    if gh_token then hdrs["Authorization"] = "token " .. gh_token end
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local dl_code = socket.skip(1, https.request{
                        url = url,
                        headers = hdrs,
                        sink = ltn12.sink.file(io.open(dest, "w")),
                    })
                    socketutil:reset_timeout()

                    if dl_code == 200 then
                        table.insert(downloaded, filename)
                    else
                        os.remove(dest)
                    end
                end

                if #downloaded == #source.files then
                    for _k, filename in ipairs(source.files) do
                        os.rename(source.dir .. filename .. ".new", source.dir .. filename)
                    end
                    plugin_updated = plugin_updated + 1
                    installed_tags[repo] = release.tag_name
                    self:saveSetting("patch_installed_tags", installed_tags)
                else
                    for _k, filename in ipairs(downloaded) do
                        os.remove(source.dir .. filename .. ".new")
                    end
                    table.insert(plugin_failed, repo_short)
                end
            elseif is_plugin and plugin_needs_update then
                local zip_asset = findZipAsset(release.assets)
                local final_url, dl_name, dl_size
                if zip_asset then
                    final_url = resolveRedirect(zip_asset.browser_download_url)
                    dl_name = zip_asset.name
                    dl_size = (zip_asset.size and zip_asset.size > 0) and zip_asset.size or nil
                else
                    -- Fallback: the release tag's source zip. codeload serves it
                    -- directly (no redirect); extractZip strips the
                    -- "owner-repo-sha/" wrapper. Covers repos that tag releases
                    -- without attaching a prebuilt .zip asset.
                    final_url = "https://codeload.github.com/" .. repo .. "/zip/refs/tags/" .. release.tag_name
                    dl_name = repo_short .. " (source)"
                end
                do
                    local tmp_zip = fetcher_tmp_dir .. "/" .. repo_short .. ".zip"
                    local progress_dialog = ProgressbarDialog:new{
                        title = T(_("Installing %1"), repo_short),
                        subtitle = dl_name,
                        progress_max = dl_size,
                        refresh_time_seconds = 1,
                    }
                    self:closeStatus()
                    progress_dialog:show()
                    UIManager:forceRePaint()

                    local file_sink = ltn12.sink.file(io.open(tmp_zip, "w"))
                    local progress_sink = socketutil.chainSinkWithProgressCallback(file_sink, function(bytes)
                        progress_dialog:reportProgress(bytes)
                    end)

                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local dl_code = socket.skip(1, https.request{
                        url = final_url,
                        headers = {
                            ["User-Agent"] = "Fetcher-KOReader",
                            ["Accept-Encoding"] = "identity",
                        },
                        sink = progress_sink,
                    })
                    socketutil:reset_timeout()
                    progress_dialog:close()

                    if dl_code ~= 200 then
                        os.remove(tmp_zip)
                        table.insert(plugin_failed, repo_short)
                    else
                        local reader = Archiver.Reader:new()
                        if not reader:open(tmp_zip) then
                            os.remove(tmp_zip)
                            table.insert(plugin_failed, repo_short)
                        else
                            -- Extract into a staging dir beside the target so a
                            -- truncated download or a mid-extraction failure can
                            -- never leave a half-installed (broken) plugin; only
                            -- a complete extraction is swapped into place. The
                            -- staging/backup names don't end in .koplugin, so
                            -- KOReader ignores any leftover from an aborted run.
                            local dest = source.dir:gsub("/+$", "")
                            local stage = dest .. ".fetcher-new"
                            removeTree(stage)
                            local extract_ok = extractZip(reader, stage .. "/")
                            reader:close()
                            os.remove(tmp_zip)

                            -- Keep the user's config/keys across the update.
                            if extract_ok then keepUserFiles(source, stage) end

                            local installed_ok = extract_ok and swapIntoPlace(stage, dest)
                            removeTree(stage) -- no-op once the swap moved it

                            if installed_ok then
                                plugin_updated = plugin_updated + 1
                                installed_tags[repo] = release.tag_name
                                self:saveSetting("patch_installed_tags", installed_tags)
                            else
                                table.insert(plugin_failed, repo_short)
                            end
                        end
                    end
                end
            elseif not is_plugin and release.tag_name ~= installed_tags[repo] then
                local assets = release.assets or {}
                -- Cache known patch names so the menu can show them before download
                local known = self:getSetting("known_patches", {})
                local repo_known = {}
                for _j, asset in ipairs(assets) do
                    if asset.name:match("%.lua$") then
                        table.insert(repo_known, asset.name)
                    end
                end
                known[repo] = repo_known
                self:saveSetting("known_patches", known)

                local repo_count = 0
                for _j, asset in ipairs(assets) do
                    if asset.name:match("%.lua$") and not disabled_patch_set[asset.name] then
                        local dest = patches_dir .. "/" .. asset.name
                        local final_url = resolveRedirect(asset.browser_download_url)

                        local progress_dialog = ProgressbarDialog:new{
                            title = _("Updating patches"),
                            subtitle = asset.name,
                            progress_max = (asset.size and asset.size > 0) and asset.size or nil,
                            refresh_time_seconds = 1,
                        }
                        self:closeStatus()
                        progress_dialog:show()
                        UIManager:forceRePaint()

                        local file_sink = ltn12.sink.file(io.open(dest, "w"))
                        local progress_sink = socketutil.chainSinkWithProgressCallback(file_sink, function(bytes)
                            progress_dialog:reportProgress(bytes)
                        end)

                        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                        local dl_code = socket.skip(1, https.request{
                            url = final_url,
                            headers = {
                                ["User-Agent"] = "Fetcher-KOReader",
                                ["Accept-Encoding"] = "identity",
                            },
                            sink = progress_sink,
                        })
                        socketutil:reset_timeout()
                        progress_dialog:close()

                        if dl_code == 200 then
                            repo_count = repo_count + 1
                        else
                            os.remove(dest)
                        end
                    end
                end

                if repo_count > 0 then
                    patch_updated = patch_updated + repo_count
                    installed_tags[repo] = release.tag_name
                    self:saveSetting("patch_installed_tags", installed_tags)
                end
            end
            end) -- end isolated per-source processing
            if not ok_iter then
                table.insert(is_plugin and plugin_failed or patch_failed, repo_short)
            end
        end
    end

    local function summarize(label, updated, failed)
        if #failed > 0 then
            return T(_("%1: %2 updated, failed: %3"), label, updated, table.concat(failed, ", "))
        end
        if updated > 0 then
            return T(_("%1: %2 updated ✓"), label, updated)
        end
        return T(_("%1: up to date ✓"), label)
    end

    local plugin_line = summarize(_("Plugins"), plugin_updated, plugin_failed)
    local patch_line = summarize(_("Patches"), patch_updated, patch_failed)
    local needs_restart = plugin_updated > 0 or patch_updated > 0
    return needs_restart, plugin_line, patch_line
end

-- Directory this plugin is running from, e.g. ".../plugins/fetcher.koplugin/"
function Fetcher:getSelfDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*/)") or "./"
end

-- Parent of Fetcher's own plugin directory, i.e. KOReader's plugins/ dir,
-- e.g. ".../plugins/". Built-in zip plugins install as siblings here.
function Fetcher:getPluginsParentDir()
    local self_dir = self:getSelfDir() -- ".../plugins/fetcher.koplugin/"
    return self_dir:match("^(.*/)[^/]+/$") or self_dir
end

-- Status bar helpers --------------------------------------------------------

-- showStatus / closeStatus keep their old callers working, but they now drive
-- the persistent top status bar (see statusbar.lua) instead of a modal
-- ProgressbarDialog. The `toast = true` trick in that widget means page-turns
-- pass through to the reader, so a sync no longer blocks reading.

-- Show the tail of the sync log (last ~50 lines) in a scrollable dialog, so
-- the user can see what actually happened when the bar flashed by too fast.
function Fetcher:showLog()
    local path = DataStorage:getSettingsDir() .. "/fetcher.log"
    local f = io.open(path, "r")
    local content
    if not f then
        content = "No sync log yet — tap 'Sync now' first."
    else
        local all = f:read("*a") or ""
        f:close()
        -- Show last N lines; the file grows but is never rotated.
        local tail = {}
        for line in all:gmatch("([^\n]+)") do
            table.insert(tail, line)
            if #tail > 80 then table.remove(tail, 1) end
        end
        content = table.concat(tail, "\n")
        if content == "" then content = "(log file is empty)" end
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Fetcher — last sync log"),
        text = content,
    })
end

-- Append a timestamped line to settings/fetcher.log. Cheap; no rotation
-- (file grows a few KB per sync). Purpose: give the user a paper trail of
-- what actually happened when the bar flashed by too fast to read.
function Fetcher:_log(msg)
    local path = DataStorage:getSettingsDir() .. "/fetcher.log"
    local f = io.open(path, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S"), "  ", tostring(msg), "\n")
    f:close()
end

-- Modal status dialog. A conscious "Sync now" tap is short — a centered
-- ProgressbarDialog is clearer than a subtle top strip trying not to
-- interrupt reading. Per-download modals underneath show byte-level progress.

function Fetcher:showStatus(title, subtitle)
    if self._status_dialog then
        UIManager:close(self._status_dialog)
    end
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    self._status_dialog = ProgressbarDialog:new{
        title = title,
        subtitle = subtitle,
    }
    UIManager:show(self._status_dialog)
    UIManager:forceRePaint()
end

function Fetcher:closeStatus()
    if self._status_dialog then
        UIManager:close(self._status_dialog)
        self._status_dialog = nil
    end
end

-- Main sync -----------------------------------------------------------------

function Fetcher:runSync()
    -- Make sure Wi-Fi is actually up before doing any network work.
    -- isConnected() (the Wi-Fi interface being associated with an IP) is the
    -- reliable signal that Wi-Fi is on; isOnline() alone is a DNS check that
    -- can occasionally pass on stale state. If we're not connected, run
    -- KOReader's connect flow (turn Wi-Fi on / prompt, per the user's
    -- settings) and re-run the sync once it's up, rather than running offline.
    if not NetworkMgr:isConnected() then
        NetworkMgr:beforeWifiAction(function() self:runSync() end)
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:_log("--- sync start ---")
        -- Wrap the whole sync body in a pcall so an unexpected error still
        -- closes the modal cleanly and reports something readable, instead of
        -- leaving a dangling status dialog on top of the reader.
        local sync_ok, sync_err = pcall(function() self:_doSync() end)
        if not sync_ok then
            self:_log("sync ERROR: " .. tostring(sync_err))
            self:closeStatus()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = "Fetcher sync failed:\n" .. tostring(sync_err),
            })
        end
        self:_log("--- sync end ---")
    end)
end

function Fetcher:_doSync()
    local enable_update = self:getSetting("enable_koreader_update", true)
    local enable_opds   = self:getSetting("enable_opds_sync", true)
    local lines = {}

    -- Step 1: KOReader update
    local ota_version, ota_package
    if enable_update then
        self:showStatus(_("KOReader Update"), _("Checking for updates…"))
        if OTAManager:getOTAType() == "none" then
            table.insert(lines, _("KOReader: emulator — skipping update"))
            self:_log("KOReader: emulator, skipped")
        else
            local _lv, _lk
            ota_version, _lv, _lk, ota_package = OTAManager:checkUpdate()
            if ota_version == 0 then
                table.insert(lines, _("KOReader: up to date ✓"))
                self:_log("KOReader: up to date")
            elseif ota_version then
                table.insert(lines, _("KOReader: update available!"))
                self:_log("KOReader: update available (" .. tostring(ota_version) .. ")")
            else
                table.insert(lines, _("KOReader: update check failed"))
                self:_log("KOReader: update check failed")
            end
        end
    else
        self:_log("KOReader update: disabled in settings")
    end

    -- Step 2: OPDS books
    if enable_opds then
        self:showStatus(_("Books"), _("Checking for new books…"))
        local ok, msg = self:syncOPDS()
        table.insert(lines, msg or _("Books: up to date ✓"))
        self:_log("OPDS: " .. tostring(msg or "up to date"))
    else
        self:_log("OPDS: disabled in settings")
    end

    -- Step 3: Plugins and patches (reported as separate lines)
    local needs_restart = false
    self:showStatus(_("Plugins & patches"), _("Checking for updates…"))
    local pcall_ok, restart, plugin_line, patch_line = pcall(function() return self:syncSources() end)
    if not pcall_ok then
        table.insert(lines, "Plugins & patches: error — " .. tostring(restart))
        self:_log("syncSources ERROR: " .. tostring(restart))
    else
        table.insert(lines, plugin_line or _("Plugins: up to date ✓"))
        table.insert(lines, patch_line or _("Patches: up to date ✓"))
        self:_log("Plugins: " .. tostring(plugin_line or "up to date"))
        self:_log("Patches: " .. tostring(patch_line or "up to date"))
        needs_restart = restart or false
    end

    -- If the sync hit GitHub's API rate limit part-way through, prepend a
    -- clear warning so the user knows the "failed" sources aren't broken —
    -- they were skipped because the API stopped answering. Include the reset
    -- time (local) and a hint about the token file that raises the limit.
    if self._rate_limited_until then
        local mins = math.max(1, math.ceil((self._rate_limited_until - os.time()) / 60))
        local reset_hhmm = os.date("%H:%M", self._rate_limited_until)
        local has_token = self:getGitHubToken() ~= nil
        local warn = string.format(
            "⚠ Hit GitHub API rate limit — retry after %s (%d min).\n"
            .. "Any \"failed\" sources below are just skipped, not broken.",
            reset_hhmm, mins)
        if not has_token then
            warn = warn .. "\nTip: add a personal-access token to "
                .. "settings/fetcher_github_token.txt to raise the limit "
                .. "from 60 to 5000/hr."
        end
        table.insert(lines, 1, warn)
        table.insert(lines, 2, "")
        self:_log("RATE-LIMITED until " .. os.date("%H:%M", self._rate_limited_until))
    end

    -- Final summary
    table.insert(lines, "")
    table.insert(lines, _("Sync complete."))
    self:closeStatus()

    if ota_version and ota_version ~= 0 then
        UIManager:scheduleIn(4, function()
            OTAManager:fetchAndProcessUpdate()
        end)
    end

    local summary_text = table.concat(lines, "\n")
    if needs_restart then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = summary_text .. "\n" .. _("Restart KOReader to apply updates?"),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    else
        UIManager:show(InfoMessage:new{ text = summary_text })
    end
end

-- Dispatcher / menu ---------------------------------------------------------

function Fetcher:onDispatcherRegisterActions()
    Dispatcher:registerAction("fetcher_run", {
        category = "none",
        event = "FetcherRun",
        title = _("Fetcher: Sync now"),
        general = true,
    })
end

function Fetcher:init()
    self:migrateLegacySettings()
    self:migrateDisabledRepos()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Fetcher:onFetcherRun()
    self:runSync()
end

function Fetcher:addToMainMenu(menu_items)
    menu_items.fetcher = {
        text = _("Fetcher"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function() self:runSync() end,
            },
            {
                text = _("Show last sync log"),
                keep_menu_open = true,
                callback = function() self:showLog() end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        -- Informational: the version of Fetcher currently
                        -- installed on this device, read live from
                        -- fetcher.koplugin/_meta.lua on each menu open.
                        text_func = function()
                            return _("Version: ") .. self:getSelfVersion()
                        end,
                        keep_menu_open = true,
                        callback = function() end,
                    },
                    {
                        text = _("KOReader update channel"),
                        sub_item_table = OTAManager:genChannelList(),
                    },
                    {
                        text = _("Enable KOReader update"),
                        checked_func = function()
                            return self:getSetting("enable_koreader_update", true)
                        end,
                        callback = function()
                            local v = self:getSetting("enable_koreader_update", true)
                            self:saveSetting("enable_koreader_update", not v)
                        end,
                    },
                    {
                        text = _("Enable OPDS book sync"),
                        checked_func = function()
                            return self:getSetting("enable_opds_sync", true)
                        end,
                        callback = function()
                            local v = self:getSetting("enable_opds_sync", true)
                            self:saveSetting("enable_opds_sync", not v)
                        end,
                    },
                    {
                        text = _("Select OPDS catalogs…"),
                        sub_item_table_func = function()
                            return self:genCatalogMenuItems()
                        end,
                    },
                    {
                        text = _("Force re-download all books on next sync"),
                        checked_func = function()
                            return self:getSetting("opds_force_resync", false)
                        end,
                        callback = function()
                            local v = self:getSetting("opds_force_resync", false)
                            self:saveSetting("opds_force_resync", not v)
                        end,
                    },
                    {
                        text = _("Plugin sources…"),
                        sub_item_table_func = function()
                            return self:genPluginMenuItems()
                        end,
                    },
                    {
                        text = _("Patch sources…"),
                        sub_item_table_func = function()
                            return self:genSourceMenuItems()
                        end,
                    },
                    {
                        text = _("Individual patches…"),
                        sub_item_table_func = function()
                            return self:genPatchMenuItems()
                        end,
                    },
                },
            },
        },
    }
end

function Fetcher:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return Fetcher
