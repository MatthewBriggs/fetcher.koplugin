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


function Fetcher:genSourceMenuItems()
    local sources = self:getSources()
    local items = {}
    for _i, source in ipairs(sources) do
        local repo = source.repo
        if repo then
            items[#items + 1] = {
                text = repo,
                checked_func = function()
                    local disabled = self:getSetting("disabled_patch_repos", {})
                    for _j, r in ipairs(disabled) do
                        if r == repo then return false end
                    end
                    return true
                end,
                callback = function()
                    local disabled = self:getSetting("disabled_patch_repos", {})
                    local found = false
                    for _j, r in ipairs(disabled) do
                        if r == repo then
                            table.remove(disabled, _j)
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(disabled, repo)
                    end
                    self:saveSetting("disabled_patch_repos", disabled)
                end,
            }
        end
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
    -- Fetcher updates itself the same way it updates any other plugin repo:
    -- it's just a built-in source, toggleable in "Patch sources…" like the rest.
    table.insert(sources, 1, {
        repo = SELF_REPO,
        type = "plugin",
        dir = self:getSelfDir(),
        files = SELF_FILES,
    })
    return sources
end

function Fetcher:syncPatches()
    local T = require("ffi/util").template
    local sources = self:getSources()

    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local json = require("rapidjson")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local lfs = require("libs/libkoreader-lfs")
    local ProgressbarDialog = require("ui/widget/progressbardialog")

    local patches_dir = DataStorage:getDataDir() .. "/patches"
    if not lfs.attributes(patches_dir) then
        lfs.mkdir(patches_dir)
    end

    local function githubGet(url)
        local chunks = {}
        socketutil:set_timeout()
        local _body, code = https.request{
            url = url,
            headers = {
                ["Accept"] = "application/vnd.github+json",
                ["User-Agent"] = "Fetcher-KOReader",
            },
            sink = ltn12.sink.table(chunks),
        }
        socketutil:reset_timeout()
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

    local installed_tags = self:getSetting("patch_installed_tags", {})
    local disabled_repos = self:getSetting("disabled_patch_repos", {})
    local disabled_set = {}
    for _i, r in ipairs(disabled_repos) do disabled_set[r] = true end
    local disabled_patches = self:getSetting("disabled_patches", {})
    local disabled_patch_set = {}
    for _i, f in ipairs(disabled_patches) do disabled_patch_set[f] = true end

    local updated_count = 0
    local failed = {}

    for _i, source in ipairs(sources) do
        local repo = source.repo
        if repo and not disabled_set[repo] then
            local repo_short = repo:match("[^/]+$") or repo
            self:showStatus(_("Patches"), T(_("Checking %1…"), repo_short))

            local release = githubGet("https://api.github.com/repos/" .. repo .. "/releases/latest")
            if not release or not release.tag_name then
                table.insert(failed, repo_short)
            elseif release.tag_name ~= installed_tags[repo] and source.type == "plugin" then
                local downloaded = {}
                for _k, filename in ipairs(source.files) do
                    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. release.tag_name .. "/" .. filename
                    local dest = source.dir .. filename .. ".new"

                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local dl_code = socket.skip(1, https.request{
                        url = url,
                        headers = {
                            ["User-Agent"] = "Fetcher-KOReader",
                            ["Accept-Encoding"] = "identity",
                        },
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
                    updated_count = updated_count + 1
                    installed_tags[repo] = release.tag_name
                    self:saveSetting("patch_installed_tags", installed_tags)
                else
                    for _k, filename in ipairs(downloaded) do
                        os.remove(source.dir .. filename .. ".new")
                    end
                    table.insert(failed, repo_short)
                end
            elseif release.tag_name ~= installed_tags[repo] then
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
                    updated_count = updated_count + repo_count
                    installed_tags[repo] = release.tag_name
                    self:saveSetting("patch_installed_tags", installed_tags)
                end
            end
        end
    end

    if #failed > 0 then
        return false, T(_("Patches: %1 updated, failed: %2"), updated_count, table.concat(failed, ", ")), updated_count > 0
    end
    if updated_count > 0 then
        return true, T(_("Patches: %1 updated ✓"), updated_count), true
    end
    return true, _("Patches: up to date ✓"), false
end

-- Directory this plugin is running from, e.g. ".../plugins/fetcher.koplugin/"
function Fetcher:getSelfDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*/)") or "./"
end

-- Status dialog helper ------------------------------------------------------

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
    NetworkMgr:runWhenOnline(function()
        local enable_update  = self:getSetting("enable_koreader_update", true)
        local enable_opds    = self:getSetting("enable_opds_sync", true)
        local T = require("ffi/util").template
        local lines = {}

        -- Step 1: KOReader update
        local ota_version, ota_package
        if enable_update then
            self:showStatus(_("KOReader Update"), _("Checking for updates…"))
            if OTAManager:getOTAType() == "none" then
                table.insert(lines, _("KOReader: emulator — skipping update"))
            else
                local _lv, _lk
                ota_version, _lv, _lk, ota_package = OTAManager:checkUpdate()
                if ota_version == 0 then
                    table.insert(lines, _("KOReader: up to date ✓"))
                elseif ota_version then
                    table.insert(lines, _("KOReader: update available!"))
                else
                    table.insert(lines, _("KOReader: update check failed"))
                end
            end
        end

        -- Step 2: OPDS books
        if enable_opds then
            self:showStatus(_("Books"), _("Checking for new books…"))
            local ok, msg = self:syncOPDS()
            table.insert(lines, msg or _("Books: up to date ✓"))
        end

        -- Step 3: Patches (and plugin self-update, same source list)
        local needs_restart = false
        self:showStatus(_("Patches"), _("Checking for updates…"))
        local pcall_ok, _sync_ok, msg, patches_restart = pcall(function() return self:syncPatches() end)
        if not pcall_ok then
            table.insert(lines, "Patches: error — " .. tostring(_sync_ok))
        else
            table.insert(lines, msg or _("Patches: up to date ✓"))
            needs_restart = patches_restart or false
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
                ok_callback = function()
                    UIManager:restartKOReader()
                end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = summary_text,
            })
        end
    end)
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
                text = _("Settings"),
                sub_item_table = {
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
