local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local OTAManager = require("ui/otamanager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ReaderSync = WidgetContainer:extend{
    name = "readersync",
    settings_file = DataStorage:getSettingsDir() .. "/readersync.lua",
    settings = nil,
}

-- Settings ------------------------------------------------------------------

function ReaderSync:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
end

function ReaderSync:getSetting(key, default)
    self:loadSettings()
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function ReaderSync:saveSetting(key, value)
    self:loadSettings()
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- OPDS catalog list ---------------------------------------------------------

function ReaderSync:getOPDSServers()
    local opds_file = DataStorage:getSettingsDir() .. "/opds.lua"
    local opds_settings = LuaSettings:open(opds_file)
    return opds_settings:readSetting("servers", {})
end

function ReaderSync:genCatalogMenuItems()
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

function ReaderSync:syncOPDS()
    local catalog_urls = self:getSetting("opds_catalog_urls", {})
    if #catalog_urls == 0 then
        return false, _("No catalogs selected for sync. Configure in ReaderSync settings.")
    end

    local opds_file = DataStorage:getSettingsDir() .. "/opds.lua"
    local opds_settings_store = LuaSettings:open(opds_file)
    local opds_settings = opds_settings_store:readSetting("settings", {})
    local servers = opds_settings_store:readSetting("servers", {})
    local downloads = opds_settings_store:readSetting("downloads", {})
    local pending_syncs = opds_settings_store:readSetting("pending_syncs", {})

    if not opds_settings.sync_dir then
        return false, _("OPDS sync folder not set. Configure it in the OPDS Catalog plugin (Sync > Set sync folder).")
    end

    -- Filter to only selected catalogs
    local selected_map = {}
    for _, url in ipairs(catalog_urls) do
        selected_map[url] = true
    end
    local sync_servers = {}
    for _, server in ipairs(servers) do
        if selected_map[server.url] then
            local s = {}
            for k, v in pairs(server) do s[k] = v end
            s.sync = true  -- force sync regardless of OPDS plugin setting
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

    -- Populate the pending download list for each selected catalog
    for _, server in ipairs(sync_servers) do
        browser:fillPendingSyncs(server)
    end

    local pending = browser.pending_syncs
    if #pending == 0 then
        return true, _("Books: up to date ✓")
    end

    -- Download each book with a per-book progress message
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local dl_count = 0
    for i, item in ipairs(pending) do
        local filename = item.file:match("([^/]+)$") or item.file

        if not lfs.attributes(item.file) then
            -- First do a HEAD request to get Content-Length
            socketutil:set_timeout()
            local _body, code, headers = http.request{
                method = "HEAD",
                url = item.url,
                user = item.username,
                password = item.password,
                sink = ltn12.sink.null(),
                headers = { ["Accept-Encoding"] = "identity" },
            }
            socketutil:reset_timeout()
            local total_bytes = (type(headers) == "table") and tonumber(headers["content-length"]) or 0

            self:showStatus(T(_("Downloading %1 of %2:\n%3\n0%"), i, #pending, filename))

            local file_sink = ltn12.sink.file(io.open(item.file, "w"))
            local last_pct = -1
            local progress_sink = socketutil.chainSinkWithProgressCallback(file_sink, function(bytes)
                if total_bytes > 0 then
                    local pct = math.floor(bytes / total_bytes * 100)
                    if pct ~= last_pct then
                        last_pct = pct
                        self:showStatus(T(_("Downloading %1 of %2:\n%3\n%4%"), i, #pending, filename, pct))
                    end
                end
            end)

            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local code = socket.skip(1, http.request{
                url = item.url,
                headers = { ["Accept-Encoding"] = "identity" },
                sink = progress_sink,
                user = item.username,
                password = item.password,
            })
            socketutil:reset_timeout()

            if code == 200 then
                dl_count = dl_count + 1
            else
                os.remove(item.file)
            end
        end
    end

    -- Flush updated last_download pointers back to OPDS settings
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

-- KOReader update -----------------------------------------------------------

function ReaderSync:syncKOReader()
    OTAManager:fetchAndProcessUpdate()
end

-- Status dialog helper ------------------------------------------------------

function ReaderSync:showStatus(text)
    if self._status_msg then
        UIManager:close(self._status_msg)
    end
    self._status_msg = InfoMessage:new{
        text = "ReaderSync\n\n" .. text,
        show_icon = false,
    }
    UIManager:show(self._status_msg)
    UIManager:forceRePaint()
end

function ReaderSync:closeStatus()
    if self._status_msg then
        UIManager:close(self._status_msg)
        self._status_msg = nil
    end
end

-- Main sync -----------------------------------------------------------------

function ReaderSync:runSync()
    NetworkMgr:runWhenOnline(function()
        local enable_update = self:getSetting("enable_koreader_update", true)
        local enable_opds   = self:getSetting("enable_opds_sync", true)
        local T = require("ffi/util").template
        local lines = {}

        -- Step 1: KOReader update
        local ota_version, ota_package
        if enable_update then
            self:showStatus(_("Checking for KOReader update…"))
            if OTAManager:getOTAType() == "none" then
                table.insert(lines, _("KOReader: emulator — skipping update"))
            else
                ota_version, _, _, ota_package = OTAManager:checkUpdate()
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
            self:showStatus(_("Checking for new books…"))
            local ok, msg = self:syncOPDS()
            table.insert(lines, msg or _("Books: sync complete ✓"))
        end

        -- Final summary
        table.insert(lines, "")
        table.insert(lines, _("Sync complete."))
        self:closeStatus()
        UIManager:show(InfoMessage:new{
            text = table.concat(lines, "\n"),
        })

        -- If OTA update is available, show confirm dialog after summary dismisses
        if ota_version and ota_version ~= 0 then
            UIManager:scheduleIn(4, function()
                OTAManager:fetchAndProcessUpdate()
            end)
        end
    end)
end

-- Dispatcher / menu ---------------------------------------------------------

function ReaderSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("readersync_run", {
        category = "none",
        event = "ReaderSyncRun",
        title = _("ReaderSync: Sync now"),
        general = true,
    })
end

function ReaderSync:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ReaderSync:onReaderSyncRun()
    self:runSync()
end

function ReaderSync:addToMainMenu(menu_items)
    menu_items.readersync = {
        text = _("ReaderSync"),
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
                },
            },
        },
    }
end

function ReaderSync:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return ReaderSync
