--[[--
App-style, full-screen user interface for the ZEIT+ plugin.

The app's two flagship screens are custom widgets (zeitpluswidgets.lua):
a branded Home screen and the "Meine Artikel" cover grid. Everything else
(browse results, settings) is a KOReader Menu page shown over the Home
widget; backing out of a page returns to the app.

@module koplugin.zeitplus.zeitplusui
]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = FFIUtil.template

local ZeitPlusWidgets = require("zeitpluswidgets")

--- Menu subclass used for the app's drill-in pages (browse results,
-- settings); in page_mode its back button closes the page instead of
-- tearing down the whole app.
local AppMenu = Menu:extend{
    page_mode = false,
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
    elseif self.page_mode then
        UIManager:close(self)
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

function ZeitPlusUI:closePage()
    if self.page_widget then
        UIManager:close(self.page_widget)
        self.page_widget = nil
    end
end

function ZeitPlusUI:closeGrid()
    if self.grid_widget then
        UIManager:close(self.grid_widget)
        self.grid_widget = nil
    end
end

function ZeitPlusUI:close()
    self:closePage()
    self:closeGrid()
    if self.home_widget then
        UIManager:close(self.home_widget)
        self.home_widget = nil
    end
end

function ZeitPlusUI:quit()
    self:close()
end

function ZeitPlusUI:refresh()
    if self.grid_widget then
        self.grid_widget:refresh()
    end
    if self.home_widget then
        self.home_widget:refresh()
    end
end

function ZeitPlusUI:showHome()
    self:closePage()
    self:closeGrid()
    self.plugin.app_ui = self
    if self.home_widget then
        self.home_widget:refresh()
        return
    end
    local home = ZeitPlusWidgets.Home:new{ ui = self }
    self.home_widget = home
    UIManager:show(home)
end

function ZeitPlusUI:showPage(title, items, subtitle)
    self:closePage()
    self.plugin.app_ui = self
    if not self.home_widget then
        self:showHome()
    end
    local menu = AppMenu:new{
        title = title,
        subtitle = subtitle,
        page_mode = true,
        item_table = items,
        close_callback = function()
            self.page_widget = nil
        end,
    }
    self.page_widget = menu
    UIManager:show(menu)
end

function ZeitPlusUI:showLibrary()
    self:closePage()
    self.plugin.app_ui = self
    if not self.home_widget then
        self:showHome()
    end
    if self.grid_widget then
        self.grid_widget:refresh()
        return
    end
    local grid = ZeitPlusWidgets.Grid:new{ ui = self }
    self.grid_widget = grid
    UIManager:show(grid)
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
            os.remove(path:gsub("%.epub$", ".cover.jpg"))
            self:refresh()
        end,
    })
end

local function notLoggedInHint()
    return {
        {
            text = _("Bitte zuerst anmelden (Einstellungen → Session-Cookies laden)."),
            select_enabled = false,
        },
    }
end

--- Gate shown instead of a source's article list when the session is
-- missing or expired (stale cookies would only produce paywall teasers).
function ZeitPlusUI:browseGate()
    local plugin = self.plugin
    if plugin:sessionExpiry() and plugin:isSessionExpired() then
        return {
            {
                text = _("Session abgelaufen – neue Cookies laden (Einstellungen → Session-Cookies laden (Datei))."),
                select_enabled = false,
            },
        }
    end
    return notLoggedInHint()
end

function ZeitPlusUI:openBrowsePage(name, url)
    local plugin = self.plugin
    if not plugin:isLoggedIn() or (plugin:sessionExpiry() and plugin:isSessionExpired()) then
        self:showPage(name, self:browseGate())
        return
    end
    local ok, res = pcall(function()
        return plugin:buildIndexMenu(url)
    end)
    if ok and type(res) == "table" and #res > 0 then
        self:showPage(name, res)
    elseif ok then
        self:showPage(name, {
            { text = _("Keine Einträge gefunden."), select_enabled = false },
        })
    else
        UIManager:show(InfoMessage:new{ text = T(_("Fehler beim Laden:\n%1"), tostring(res)) })
    end
end

function ZeitPlusUI:buildLibrary()
    local plugin = self.plugin
    local files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin.download_dir)
    if ok and iter then
        for entry in iter, dir_obj do
            if entry:lower():match("%.epub$") then
                local path = plugin.download_dir .. entry
                local mtime = lfs.attributes(path, "modification") or 0
                table.insert(files, {
                    title = entry:gsub("^%d%d%-%d%d%-%d%d[_-]", ""):gsub("%.epub$", ""),
                    date = os.date("%d.%m.%Y", mtime),
                    path = path,
                    cover = path:gsub("%.epub$", ".cover.jpg"),
                    mtime = mtime,
                })
            end
        end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    return files
end

function ZeitPlusUI:buildHomeData()
    local plugin = self.plugin

    local header = { title = "ZEIT+", pill = "", pill_color = Blitbuffer.COLOR_DARK_GRAY, subtitle = "" }
    local exp = plugin:sessionExpiry()
    if not exp then
        header.pill = _("Nicht angemeldet")
        header.subtitle = _("Cookies laden: Einstellungen → Session-Cookies laden (Datei)")
    else
        local remaining = exp - os.time()
        header.pill = plugin:sessionCountdownLabel() or _("Session läuft")
        if remaining <= 0 then
            header.pill_color = Blitbuffer.COLOR_RED
        elseif remaining < 86400 then
            header.pill_color = Blitbuffer.COLOR_ORANGE
        else
            header.pill_color = Blitbuffer.COLOR_GREEN
        end
        header.subtitle = T(_("Angemeldet als %1"), plugin:accountEmail() or plugin.username or "?")
    end

    local rows = {}
    local sources = plugin:feedSourceList()
    if #sources == 0 then
        table.insert(rows, {
            text = _("Bitte zuerst Quellen in den Einstellungen eintragen."),
        })
    else
        for _, source in ipairs(sources) do
            local name, url = source.name, source.url
            table.insert(rows, {
                text = name,
                bold = false,
                callback = function()
                    self:openBrowsePage(name, url)
                end,
            })
        end
    end

    table.insert(rows, {
        text = _("Meine Artikel"),
        bold = true,
        callback = function()
            self:showLibrary()
        end,
    })
    table.insert(rows, {
        text = _("Link hinzufügen"),
        callback = function()
            plugin:showAddArticleDialog()
        end,
    })
    table.insert(rows, {
        text = _("Einstellungen"),
        callback = function()
            self:showPage(_("Einstellungen"), self:buildSettings())
        end,
    })

    return { header = header, rows = rows }
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
            text = _("Downloads-Ordner öffnen"),
            callback = function()
                self:close()
                plugin:openDownloadsFolder()
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

return ZeitPlusUI