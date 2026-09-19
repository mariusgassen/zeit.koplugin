--[[--
ZEIT+ plugin for KOReader.

Lets you log into your ZEIT+ subscription and download individual
zeit.de articles (full text, with images) as EPUBs you can read
comfortably on an e-reader instead of your phone.

@module koplugin.zeitplus
]]

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ZeitApi = require("zeitapi")
local _ = require("gettext")
local T = FFIUtil.template

local ZeitPlus = WidgetContainer:extend{
    name = "zeitplus",
    settings_file = DataStorage:getSettingsDir() .. "/zeitplus.lua",
    zp_settings = nil,
    updated = nil,
}

local function parseCommaSeparatedOption(opt)
    local result = {}
    if type(opt) == "string" then
        for part in opt:gmatch("([^,]+)") do
            table.insert(result, util.trim(part))
        end
    end
    return result
end

function ZeitPlus:loadSettings()
    if not ZeitPlus.settings then
        ZeitPlus.settings = LuaSettings:open(self.settings_file)
        if not next(ZeitPlus.settings.data) then
            ZeitPlus.settings.data = { zeitplus = {} }
            self.updated = true
        end
    end
    self.zp_settings = ZeitPlus.settings
end

function ZeitPlus:onFlushSettings()
    if self.updated then
        self.zp_settings:saveSetting("zeitplus", {
            username = self.username,
            password = self.password,
            cookies = self.cookies,
            download_dir = self.download_dir,
            include_images = self.include_images,
            article_selectors = self.article_selectors,
            unwanted_selectors = self.unwanted_selectors,
            feed_url = self.feed_url,
        })
        self.zp_settings:flush()
        self.updated = nil
    end
end

function ZeitPlus:init()
    self:loadSettings()
    local data = self.zp_settings.data.zeitplus

    self.username = data.username
    self.password = data.password
    self.cookies = data.cookies
    self.download_dir = data.download_dir
    if not self.download_dir or self.download_dir == "" then
        self.download_dir = ("%s/%s/"):format(DataStorage:getFullDataDir(), "zeitplus")
    end
    if not lfs.attributes(self.download_dir, "mode") then
        lfs.mkdir(self.download_dir)
    end
    if data.include_images == nil then
        self.include_images = true
    else
        self.include_images = data.include_images
    end
    self.article_selectors = data.article_selectors
    self.unwanted_selectors = data.unwanted_selectors
    self.feed_url = data.feed_url
    if not self.feed_url or self.feed_url == "" then
        self.feed_url = ZeitApi.default_feed_url
    end

    self.ui.menu:registerToMainMenu(self)
end

function ZeitPlus:isLoggedIn()
    return self.cookies ~= nil and #self.cookies > 0
end

--- Performs the login HTTP call and persists the resulting cookies.
-- Shows an InfoMessage with the outcome. Returns true on success.
function ZeitPlus:doLogin(username, password)
    if not username or username == "" or not password or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Bitte E-Mail und Passwort eingeben.") })
        return false
    end
    local ok, result = ZeitApi:login(username, password)
    if ok then
        self.username = username
        self.password = password
        self.cookies = result
        self.updated = true
        self:onFlushSettings()
        UIManager:show(InfoMessage:new{ text = _("Erfolgreich bei ZEIT+ angemeldet.") })
        return true
    else
        UIManager:show(InfoMessage:new{ text = result })
        return false
    end
end

function ZeitPlus:logout()
    self.cookies = nil
    self.password = nil
    self.updated = true
    self:onFlushSettings()
    UIManager:show(InfoMessage:new{ text = _("Abgemeldet.") })
end

function ZeitPlus:showLoginDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Bei ZEIT+ anmelden"),
        fields = {
            { text = self.username or "", hint = _("E-Mail") },
            { text = "", text_type = "password", hint = _("Passwort") },
        },
        buttons = {
            {
                {
                    text = _("Abbrechen"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Anmelden"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        self:doLogin(util.trim(fields[1]), fields[2])
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Fetches the article at `url` and writes it as an EPUB to the download
-- folder. Meant to be called from inside a Trapper:wrap() context so
-- ZeitApi:createEpub()'s progress messages are shown.
function ZeitPlus:fetchArticle(url)
    local UI = require("ui/trapper")
    UI:info(_("Lade Artikel…"))

    local content_type, html = ZeitApi:loadPage(url, self.cookies, nil)
    content_type = content_type and util.trim(content_type:match("^[^;]*") or content_type) or ""
    if not content_type:find("html") then
        error(_("Die URL liefert keinen HTML-Artikel."))
    end

    if ZeitApi:isLikelyPaywalled(html) then
        local go_on = UI:confirm(
            _("Dieser Artikel scheint noch hinter der Bezahlschranke zu stecken (Anmeldung evtl. abgelaufen). Trotzdem als EPUB speichern?"),
            _("Abbrechen"), _("Trotzdem speichern")
        )
        if not go_on then
            error(ZeitApi.dismissed_error_code)
        end
    end

    local meta = ZeitApi:extractArticleMeta(html)
    local title = meta.title or url
    local safe_title = util.getSafeFilename(title, nil, 100)
    local file_path = ("%s%s_%s.epub"):format(self.download_dir, os.date("%y-%m-%d"), safe_title)

    if lfs.attributes(file_path, "mode") == "file" then
        UIManager:show(InfoMessage:new{ text = T(_("Bereits heruntergeladen:\n%1"), BD.filepath(file_path)) })
        return
    end

    local article_selectors = parseCommaSeparatedOption(self.article_selectors)
    local unwanted_selectors = parseCommaSeparatedOption(self.unwanted_selectors)
    local created = ZeitApi:createEpub(
        file_path, html, url, meta, self.include_images, title,
        #article_selectors > 0 and article_selectors or nil,
        #unwanted_selectors > 0 and unwanted_selectors or nil
    )
    if created then
        UIManager:show(InfoMessage:new{ text = T(_("Artikel gespeichert:\n%1"), BD.filepath(file_path)) })
    end
end

function ZeitPlus:downloadArticleUrl(url)
    url = util.trim(url or "")
    if url == "" then return end
    if not url:match("^https?://") then
        UIManager:show(InfoMessage:new{ text = _("Bitte eine vollständige Artikel-URL eingeben (https://www.zeit.de/…).") })
        return
    end
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{ text = _("Bitte zuerst bei ZEIT+ anmelden.") })
        return
    end

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local ok, err = pcall(function() self:fetchArticle(url) end)
        if not ok and err ~= ZeitApi.dismissed_error_code then
            UIManager:show(InfoMessage:new{ text = T(_("Fehler beim Herunterladen:\n%1"), tostring(err)) })
        end
    end)
end

function ZeitPlus:showAddArticleDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Artikel-URL hinzufügen"),
        input = "",
        input_hint = "https://www.zeit.de/…",
        buttons = {
            {
                {
                    text = _("Abbrechen"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Herunterladen"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:downloadArticleUrl(url)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Builds the "Artikel aus Feed" submenu entries: fetches and parses the
-- configured feed, then returns one tappable item per article, which
-- downloads that article (keeping the submenu open so several articles
-- can be picked in one go).
function ZeitPlus:buildFeedMenu()
    local feed_url = util.trim(self.feed_url or "")
    if feed_url == "" then
        return { { text = _("Bitte zuerst eine Feed-URL in den Einstellungen eintragen."), enabled = false } }
    end

    local ok, result = pcall(function() return ZeitApi:fetchFeed(feed_url, self.cookies) end)
    if not ok then
        return { { text = T(_("Fehler beim Laden des Feeds:\n%1"), tostring(result)), enabled = false } }
    end
    if #result == 0 then
        return { { text = _("Feed enthält keine Artikel (oder Format wird nicht erkannt)."), enabled = false } }
    end

    local items = {}
    for _, entry in ipairs(result) do
        table.insert(items, {
            text = util.htmlEntitiesToUtf8(entry.title),
            keep_menu_open = true,
            callback = function() self:downloadArticleUrl(entry.link) end,
        })
    end
    return items
end

function ZeitPlus:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.download_dir = path .. "/"
            self.updated = true
            self:onFlushSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }:chooseDir()
end

function ZeitPlus:openDownloadsFolder()
    local FileManager = require("apps/filemanager/filemanager")
    if self.ui.document then
        self.ui:onClose()
    end
    if FileManager.instance then
        FileManager.instance:reinit(self.download_dir)
    else
        FileManager:showFiles(self.download_dir)
    end
end

local function selectorInputDialog(title, hint, current, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = hint,
        buttons = {
            {
                { text = _("Abbrechen"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = _("Speichern"),
                    is_enter_default = true,
                    callback = function()
                        on_save(dialog:getInputText())
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ZeitPlus:addToMainMenu(menu_items)
    menu_items.zeitplus = {
        text = _("ZEIT+"),
        sub_item_table = {
            {
                text_func = function()
                    if self:isLoggedIn() then
                        return T(_("Angemeldet als: %1"), self.username or "?")
                    end
                    return _("Nicht angemeldet")
                end,
                keep_menu_open = true,
                callback = function()
                    if self:isLoggedIn() then
                        self:logout()
                    else
                        self:showLoginDialog()
                    end
                end,
                separator = true,
            },
            {
                text = _("Artikel-URL hinzufügen"),
                keep_menu_open = true,
                callback = function()
                    self:showAddArticleDialog()
                end,
            },
            {
                text = _("Artikel aus Feed"),
                sub_item_table_func = function()
                    return self:buildFeedMenu()
                end,
            },
            {
                text = _("Downloads-Ordner öffnen"),
                callback = function()
                    self:openDownloadsFolder()
                end,
            },
            {
                text = _("Einstellungen"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Zielordner: %1"), BD.dirpath(filemanagerutil.abbreviate(self.download_dir)))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setDownloadDirectory(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Bilder herunterladen"),
                        checked_func = function() return self.include_images end,
                        callback = function()
                            self.include_images = not self.include_images
                            self.updated = true
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Feed-URL: %1"), self.feed_url or "")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            selectorInputDialog(
                                _("RSS/Atom-Feed-URL"),
                                "https://newsfeed.zeit.de/index",
                                self.feed_url,
                                function(text)
                                    text = util.trim(text)
                                    self.feed_url = text ~= "" and text or ZeitApi.default_feed_url
                                    self.updated = true
                                    self:onFlushSettings()
                                end
                            )
                        end,
                    },
                    {
                        text = _("Artikel-Selektoren anpassen"),
                        keep_menu_open = true,
                        callback = function()
                            selectorInputDialog(
                                _("CSS-Selektoren für den Artikeltext"),
                                "article, div.article-body, …",
                                self.article_selectors,
                                function(text)
                                    self.article_selectors = text
                                    self.updated = true
                                    self:onFlushSettings()
                                end
                            )
                        end,
                    },
                    {
                        text = _("Auszuschließende Elemente anpassen"),
                        keep_menu_open = true,
                        callback = function()
                            selectorInputDialog(
                                _("CSS-Selektoren für auszuschließende Elemente"),
                                "div.article__social, aside, …",
                                self.unwanted_selectors,
                                function(text)
                                    self.unwanted_selectors = text
                                    self.updated = true
                                    self:onFlushSettings()
                                end
                            )
                        end,
                    },
                },
            },
        },
    }
end

return ZeitPlus
