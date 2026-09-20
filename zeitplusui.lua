--[[--
App-style, full-screen user interface for the ZEIT+ plugin.

Replaces the plugin's nested touch menus with a single, full-screen
"app" spreading over KOReader's modern Menu widget: a home screen with
the DIE ZEIT branding and the subscription status, browsing (Stöbern,
Ausgaben des Jahres), the article library (read/delete downloads), "Link
hinzufügen" and the settings - all reachable from one place.

@module koplugin.zeitplus.zeitplusui
]]

local ConfirmBox = require("ui/widget/confirmbox")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = FFIUtil.template

--- Menu subclass that behaves like an app: items drill into sub-pages
-- without closing, and dialogs leave the app open underneath.
local AppMenu = Menu:extend{
    home_title = nil,
    home_subtitle = nil,
    home_item_table = nil,
}

function AppMenu:init()
    self.home_title = self.title
    self.home_subtitle = self.subtitle
    self.home_item_table = self.item_table
    Menu.init(self)
end

local function menuItemLabel(item)
    if type(item.text) == "string" and item.text ~= "" then
        return item.text
    end
    if item.text_func then
        local label = item.text_func()
        if type(label) == "string" and label ~= "" then
            return label
        end
    end
    return "?"
end

function AppMenu:pushDrill(label, sub_item_table)
    self.item_table.title = self.title
    table.insert(self.item_table_stack, self.item_table)
    self:switchItemTable(label, sub_item_table)
end

function AppMenu:goHome()
    self.item_table_stack = {}
    self:switchItemTable(self.home_title, self.home_item_table, nil, nil, self.home_subtitle)
end

function AppMenu:onLeftButtonTap()
    if #self.item_table_stack > 0 then
        self:goHome()
    else
        self:onCloseAllMenus()
    end
    return true
end

function AppMenu:onMenuSelect(item)
    if item.sub_item_table then
        self:pushDrill(menuItemLabel(item), item.sub_item_table)
        return true
    end
    if item.sub_item_table_func then
        local ok, res = pcall(item.sub_item_table_func)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Fehler beim Laden:\n%1"), tostring(res)) })
            return true
        end
        if type(res) == "table" and #res > 0 then
            self:pushDrill(menuItemLabel(item), res)
        else
            UIManager:show(InfoMessage:new{ text = _("Keine Einträge gefunden.") })
        end
        return true
    end
    if item.select_enabled == false or (item.select_enabled_func and not item.select_enabled_func()) then
        return true
    end
    if item.callback then
        local ok, err = pcall(item.callback)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Fehler:\n%1"), tostring(err)) })
        end
    end
    return true
end

function AppMenu:onMenuHold(item)
    if item.hold_callback then
        item.hold_callback()
    end
    return true
end

--- Controller: builds and shows the app's screens.
local ZeitPlusUI = {}

function ZeitPlusUI:new(plugin)
    local o = setmetatable({}, { __index = ZeitPlusUI })
    o.plugin = plugin
    return o
end

function ZeitPlusUI:showMenu(opts)
    self:close()
    local menu = AppMenu:new{
        title = opts.title,
        subtitle = opts.subtitle,
        title_bar_fm_style = opts.title_bar_fm_style,
        title_bar_left_icon = opts.title_bar_left_icon,
        item_table = opts.item_table,
        close_callback = function()
            self.menu = nil
        end,
    }
    self.menu = menu
    -- So the plugin can close the app UI (e.g. before auto-opening a
    -- downloaded article in the reader).
    self.plugin.app_ui = self
    UIManager:show(menu)
end

function ZeitPlusUI:close()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

function ZeitPlusUI:refresh()
    if self.menu then
        self.menu:updateItems()
    end
end

local function notLoggedInHint()
    return { { text = _("Bitte zuerst anmelden (Einstellungen → Session-Cookies laden)."), select_enabled = false } }
end

--- Gate shown instead of a source's article list when the session is
-- missing or expired (stale cookies would only produce paywall teasers).
function ZeitPlusUI:browseGate()
    local plugin = self.plugin
    if plugin:sessionExpiry() and plugin:isSessionExpired() then
        return {
            { text = _("Session abgelaufen – neue Cookies laden (Einstellungen → Session-Cookies laden (Datei))."), select_enabled = false },
        }
    end
    return notLoggedInHint()
end

function ZeitPlusUI:buildLibrary()
    local plugin = self.plugin
    local files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin.download_dir)
    if ok and iter then
        for entry in iter, dir_obj do
            if entry:lower():match("%.epub$") then
                local mtime = lfs.attributes(plugin.download_dir .. entry, "modification")
                table.insert(files, { name = entry, path = plugin.download_dir .. entry, mtime = mtime or 0 })
            end
        end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)

    local items = {}
    for _, file in ipairs(files) do
        local title = file.name:gsub("^%d%d%-%d%d%-%d%d[_-]", ""):gsub("%.epub$", "")
        table.insert(items, {
            text = title,
            mandatory = os.date("%d.%m.%Y", file.mtime),
            callback = function()
                self:openBook(file.path)
            end,
            hold_callback = function()
                self:confirmDelete(file.path, title)
            end,
        })
    end
    if #items == 0 then
        return { { text = _("Noch keine Artikel heruntergeladen."), select_enabled = false } }
    end
    return items
end

function ZeitPlusUI:openBook(path)
    local ReaderUI = require("apps/reader/readerui")
    self:close()
    local ok, err = pcall(function() ReaderUI:showReader(path) end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Konnte Artikel nicht öffnen:\n%1"), tostring(err)) })
    end
end

function ZeitPlusUI:confirmDelete(path, title)
    UIManager:show(ConfirmBox:new{
        text = T(_("'%1' löschen?"), title),
        ok_text = _("Löschen"),
        cancel_text = _("Abbrechen"),
        ok_callback = function()
            os.remove(path)
            if self.menu then
                self.menu:switchItemTable(_("Meine Artikel"), self:buildLibrary())
            end
        end,
    })
end

function ZeitPlusUI:buildSettings()
    local plugin = self.plugin
    return {
        {
            text = _("Session-Cookies laden (Datei)"),
            callback = function()
                plugin:loadCookiesFromFile()
                self:refresh()
            end,
        },
        {
            text_func = function()
                return T(_("Zielordner: %1"), filemanagerutil.abbreviate(plugin.download_dir))
            end,
            callback = function()
                plugin:setDownloadDirectory()
            end,
        },
        {
            text = _("Bilder herunterladen"),
            mandatory_func = function()
                if plugin.include_images then return "✓" end
                return "✗"
            end,
            callback = function()
                plugin.include_images = not plugin.include_images
                plugin.updated = true
                self:refresh()
            end,
        },
        {
            text = _("Quellen zum Stöbern anpassen"),
            callback = function() plugin:editFeedSources() end,
        },
        {
            text = _("Artikel-Selektoren anpassen"),
            callback = function() plugin:editArticleSelectors() end,
        },
        {
            text = _("Auszuschließende Elemente anpassen"),
            callback = function() plugin:editUnwantedSelectors() end,
        },
        {
            text = _("Anmelden (E-Mail/Passwort)"),
            callback = function() plugin:showLoginDialog() end,
        },
        {
            text = _("Von ZEIT+ abmelden"),
            callback = function() plugin:logout() end,
        },
    }
end

function ZeitPlusUI:showHome()
    local plugin = self.plugin

    -- Flat: the configured sources (Übersicht, Nur ZEIT+, Ausgaben des
    -- Jahres, …) are direct entries; each drills straight into its
    -- article list. No extra "Stöbern" level.
    local home_items = {}
    local sources = plugin:feedSourceList()
    if #sources == 0 then
        table.insert(home_items, {
            text = _("Bitte zuerst Quellen in den Einstellungen eintragen."),
            select_enabled = false,
        })
    else
        for idx, source in ipairs(sources) do
            local url = source.url
            table.insert(home_items, {
                text = source.name,
                sub_item_table_func = function()
                    if not plugin:isLoggedIn() then return self:browseGate() end
                    if plugin:sessionExpiry() and plugin:isSessionExpired() then return self:browseGate() end
                    return plugin:buildIndexMenu(url)
                end,
            })
        end
    end

    table.insert(home_items, {
        text = _("Meine Artikel"),
        sub_item_table_func = function() return self:buildLibrary() end,
    })
    table.insert(home_items, {
        text = _("Link hinzufügen"),
        callback = function() plugin:showAddArticleDialog() end,
    })
    table.insert(home_items, {
        text = _("Downloads-Ordner öffnen"),
        callback = function()
            self:close()
            plugin:openDownloadsFolder()
        end,
    })
    table.insert(home_items, {
        text = _("Einstellungen"),
        sub_item_table_func = function() return self:buildSettings() end,
    })
    table.insert(home_items, {
        text_func = function()
            if plugin:isLoggedIn() then
                return T(_("Angemeldet als %1"), plugin:accountEmail() or plugin.username or "?")
            end
            return _("Nicht angemeldet")
        end,
        mandatory_func = function()
            return plugin:sessionCountdownLabel()
        end,
        callback = function()
            if plugin:isLoggedIn() then
                UIManager:show(ConfirmBox:new{
                    text = _("Von ZEIT+ abmelden?"),
                    ok_text = _("Abmelden"),
                    cancel_text = _("Abbrechen"),
                    ok_callback = function() plugin:logout() end,
                })
            else
                plugin:loadCookiesFromFile()
            end
        end,
    })

    local subtitle
    if plugin:isLoggedIn() then
        local countdown = plugin:sessionCountdownLabel()
        if countdown then
            subtitle = "ZEIT+ · " .. T(_("Session %1"), countdown)
        else
            subtitle = "ZEIT+ · " .. _("Angemeldet")
        end
    else
        subtitle = "ZEIT+ · " .. _("Nicht angemeldet")
    end

    self:showMenu{
        title = _("DIE ZEIT"),
        subtitle = subtitle,
        title_bar_fm_style = true,
        title_bar_left_icon = "home",
        item_table = home_items,
    }
end

return ZeitPlusUI