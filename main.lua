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

--- Default "Name = URL" list of browsable ZEIT overview pages, offered
-- until the user customizes it in the settings.
local function defaultFeedSourcesText()
    return table.concat({
        _("Übersicht") .. " = https://www.zeit.de/index",
        _("Nur ZEIT+") .. " = https://www.zeit.de/exklusive-zeit-artikel",
        _("Ausgaben des Jahres") .. " = https://www.zeit.de/" .. os.date("%Y") .. "/index",
    }, "\n")
end

--- Parses the "Name = URL" (one per line) feed_sources setting into an
-- ordered list of { name, url }. A line without "=" uses the URL itself
-- as its name. Blank lines and lines without a URL are skipped.
local function parseFeedSources(text)
    local sources = {}
    for line in (text or ""):gmatch("[^\n]+") do
        line = util.trim(line)
        if line ~= "" then
            local name, url = line:match("^(.-)%s*=%s*(https?://.+)$")
            if not url then
                name, url = nil, line:match("^(https?://.+)$")
            end
            if url then
                table.insert(sources, { name = (name and name ~= "" and name) or url, url = url })
            end
        end
    end
    return sources
end

--- Parses a cookies text (e.g. pasted/copied from a browser) into the
-- cookie list the plugin uses. Accepts one "name=value" per line, a
-- semicolon-separated list, or a browser table row ("name<TAB>value ...").
-- Lines starting with "#" are comments; empty values are ignored.
local function parseCookies(text)
    local cookies = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        for seg in (line .. ";"):gmatch("([^;]*);") do
            seg = util.trim(seg)
            if seg ~= "" and seg:sub(1, 1) ~= "#" then
                local name, value = seg:match("^(.-)%s*=%s*(.*)$")
                if not value then
                    name, value = seg:match("^(%S+)%s+(%S.*)$")
                end
                if value then
                    name = util.trim(name or "")
                    value = util.trim(value)
                    value = value:gsub("^\"(.*)\"$", "%1")
                    if name ~= "" and value ~= "" and value ~= "PASTE_HERE" then
                        cookies[#cookies + 1] = { name = name, value = value }
                    end
                end
            end
        end
    end
    return cookies
end

--- Decodes a base64url string to ASCII bytes, or returns nil on garbage.
local function b64urlDecode(s)
    local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    s = s:gsub("-", "+"):gsub("_", "/")
    local out = {}
    local val, bits = 0, 0
    for i = 1, #s do
        local char = s:sub(i, i)
        if char == "=" then break end
        local b = B64_CHARS:find(char, 1, true)
        if not b then return nil end
        b = b - 1
        val = val * 64 + b
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(math.floor(val / (2 ^ bits)) % 256)
            val = val % (2 ^ bits)
        end
    end
    return table.concat(out)
end

--- Returns the value of the cookie with the given name, or nil.
local function cookieValue(cookies, name)
    for idx, c in ipairs(cookies or {}) do
        if c.name == name then return c.value end
    end
    return nil
end

--- Returns the decoded JWT payload of a cookie value, or nil.
local function jwtPayload(value)
    local payload = tostring(value or ""):match("^[^.]*%.([^.]*)%.")
    if payload then return b64urlDecode(payload) end
    return nil
end

--- Best-effort: reads the "email" claim from ZEIT's session cookie (a JWT)
-- so the menu can show who is logged in even without a stored username.
local function sessionEmailFromCookies(cookies)
    local payload = jwtPayload(cookieValue(cookies, "zeit_sso_session_201501"))
    if payload then
        return payload:match('"email"%s*:%s*"([^"]+)"')
    end
    return nil
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
            feed_sources = self.feed_sources,
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
    self.feed_sources = data.feed_sources
    if not self.feed_sources or self.feed_sources == "" then
        self.feed_sources = defaultFeedSourcesText()
    end

    -- If zeitplus_cookies.txt was updated via SSH, pick up the newer
    -- session automatically instead of keeping the possibly-expired one.
    self:refreshCookiesFromFile()

    self.ui.menu:registerToMainMenu(self)
end

function ZeitPlus:isLoggedIn()
    return self.cookies ~= nil and #self.cookies > 0
end

--- Reads the "email" claim from the logged-in session cookie (a JWT), if any.
function ZeitPlus:accountEmail()
    return sessionEmailFromCookies(self.cookies)
end

--- Expiry time (Unix seconds) of the ZEIT+ session cookie, or nil.
function ZeitPlus:sessionExpiry()
    local payload = jwtPayload(cookieValue(self.cookies, "zeit_sso_session_201501"))
    if payload then
        return tonumber(payload:match('"exp"%s*:%s*([%d]+)'))
    end
    return nil
end

--- Returns true if the session cookie is expired or missing.
function ZeitPlus:isSessionExpired()
    local exp = self:sessionExpiry()
    if exp == nil then return true end
    return exp <= os.time()
end

--- Human-readable remaining validity of the session ("läuft in X Tagen, Y Std. ab"),
-- "Session abgelaufen", or nil when no parseable exp claim exists.
function ZeitPlus:sessionExpiryLabel()
    local exp = self:sessionExpiry()
    if exp == nil then return nil end
    local remaining = exp - os.time()
    if remaining <= 0 then
        return _("Session abgelaufen")
    end
    local days = math.floor(remaining / 86400)
    local hours = math.floor((remaining % 86400) / 3600)
    if days <= 0 then
        return T(_("Session läuft in %1 Std. ab"), hours)
    end
    if days == 1 then
        return T(_("Session läuft in 1 Tag, %1 Std. ab"), hours)
    end
    return T(_("Session läuft in %1 Tagen, %2 Std. ab"), days, hours)
end

--- Short form of the remaining session validity for tight UI spots:
-- "2 T 14 h", "5 h", "12 min", "abgelaufen" or nil when not logged in.
function ZeitPlus:sessionCountdownLabel()
    if not self:isLoggedIn() then return nil end
    local exp = self:sessionExpiry()
    if exp == nil then return _("abgelaufen") end
    local remaining = exp - os.time()
    if remaining <= 0 then return _("abgelaufen") end
    local days = math.floor(remaining / 86400)
    local hours = math.floor((remaining % 86400) / 3600)
    if days > 0 then
        if hours > 0 then return T(_("%1 T %2 h"), days, hours) end
        return T(_("%1 T"), days)
    end
    if hours > 0 then return T(_("%1 h"), hours) end
    return T(_("%1 min"), math.max(1, math.floor(remaining / 60)))
end

--- The parsed "Name = URL" list of browseable sources.
function ZeitPlus:feedSourceList()
    return parseFeedSources(self.feed_sources)
end

--- Auto-reloads the session cookies from zeitplus_cookies.txt when the file
-- contains a *newer* session than the one currently in memory (this happens
-- when the file is updated via SSH but the plugin still holds the last ones
-- from zeitplus.lua). Returns true if updated.
function ZeitPlus:refreshCookiesFromFile()
    local f = io.open(self:cookiesFilePath(), "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    local file_cookies = parseCookies(content)
    local file_exp
    local payload = jwtPayload(cookieValue(file_cookies, "zeit_sso_session_201501"))
    if payload then
        file_exp = tonumber(payload:match('"exp"%s*:%s*([%d]+)'))
    end
    if not file_exp then return false end
    local stored_exp = self:sessionExpiry()
    if stored_exp == nil or file_exp > stored_exp then
        self.cookies = file_cookies
        self.updated = true
        self:onFlushSettings()
        return true
    end
    return false
end

--- Closes the app UI (if open) and opens the freshly downloaded EPUB in the
-- reader. Called after a successful download.
function ZeitPlus:openDownloaded(file_path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        if self.app_ui then
            self.app_ui:close()
        end
        local ok, err = pcall(function() ReaderUI:showReader(file_path) end)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Konnte Artikel nicht öffnen:\n%1"), tostring(err)) })
        end
    end)
end

--- Path of the plain-text cookie file the user fills via SSH.
function ZeitPlus:cookiesFilePath()
    return DataStorage:getSettingsDir() .. "/zeitplus_cookies.txt"
end

--- Creates a template cookie file if none exists yet.
function ZeitPlus:writeCookiesTemplate()
    local path = self:cookiesFilePath()
    if lfs.attributes(path, "mode") then return end
    local template = [[# ZEIT+ Session-Cookies - eine Cookie pro Zeile im Format: name=value
# So bekommst du die Werte:
#   1. www.zeit.de im Browser offnen und anmelden
#   2. Entwicklertools (F12) -> Application -> Cookies -> www.zeit.de
#   3. Werte der beiden Cookies hier eintragen (leer lassen = nicht senden).
zeit_sso_201501=
zeit_sso_session_201501=
]]
    local f = io.open(path, "w")
    if f then
        f:write(template)
        f:close()
    end
end

--- Loads session cookies from the plain-text cookie file (editable via
-- SSH) and persists them, replacing any existing login. Shows the result
-- as an InfoMessage. Returns true on success.
function ZeitPlus:loadCookiesFromFile()
    local path = self:cookiesFilePath()
    local f = io.open(path, "r")
    if not f then
        self:writeCookiesTemplate()
        UIManager:show(InfoMessage:new{ text = T(_("Keine Cookie-Datei gefunden.\nEine Vorlage wurde angelegt. Fülle sie mit deinen Session-Cookies und lade sie dann erneut:\n%1"), BD.filepath(path)) })
        return false
    end
    local content = f:read("*a")
    f:close()
    local cookies = parseCookies(content)
    if #cookies == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("Keine gültigen Cookies in der Datei gefunden.\nFormat: eine name=value-Zeile pro Cookie.\n\nDatei:\n%1"), BD.filepath(path)) })
        return false
    end
    self.cookies = cookies
    self.updated = true
    self:onFlushSettings()
    local email = sessionEmailFromCookies(cookies) or self.username
    if email then
        UIManager:show(InfoMessage:new{ text = T(_("Cookies geladen. Angemeldet als: %1"), email) })
    else
        UIManager:show(InfoMessage:new{ text = _("Cookies geladen. Angemeldet.") })
    end
    return true
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

    local used_url, content_type, html = ZeitApi:loadArticlePage(url, self.cookies, nil)
    content_type = content_type and util.trim(content_type:match("^[^;]*") or content_type) or ""
    if not content_type:find("html") then
        error(_("Die URL liefert keinen HTML-Artikel."))
    end

    -- Always keep the page that was actually processed, so that a wrong
    -- result (e.g. only the AI summary being saved) can be inspected.
    local debug_last = io.open(self.download_dir .. "zeitplus_debug_last.html", "w")
    if debug_last then
        debug_last:write(("<!-- used_url: %s -->\n"):format(used_url))
        debug_last:write(html)
        debug_last:close()
    end

    if ZeitApi:isLikelyPaywalled(html) then
        logger.dbg("ZeitPlus: paywall marker %q on %s", ZeitApi:paywallMarker(html), used_url)
        -- Keep a copy of the suspicious page for debugging, so zeit.de's
        -- actual answer can be inspected when cookies are known-fresh.
        local debug_path = self.download_dir .. "zeitplus_paywall_debug.html"
        local df = io.open(debug_path, "w")
        if df then
            df:write(html)
            df:close()
        end

        local hint
        if self:sessionExpiry() == nil then
            hint = _("Es sind keine Session-Cookies geladen – ZEIT+ Artikel bleiben gesperrt.\nLade Cookies unter Einstellungen → Session-Cookies laden (Datei).\nTrotzdem als EPUB speichern?")
        elseif self:isSessionExpired() then
            hint = T(_("Die ZEIT+ Session ist abgelaufen (da %1).\nLade neue Cookies unter Einstellungen → Session-Cookies laden (Datei).\nTrotzdem als EPUB speichern?"), os.date("%d.%m.%Y %H:%M", self:sessionExpiry()))
        else
            hint = _("Dieser Artikel scheint trotz gültiger Session hinter der Bezahlschranke zu stecken.\nLiegt die Sperre vor (DEBUG: zeitplus_paywall_debug.html), starte neu.\nTrotzdem als EPUB speichern?")
        end
        local go_on = UI:confirm(hint, _("Abbrechen"), _("Trotzdem speichern"))
        if not go_on then
            error(ZeitApi.dismissed_error_code)
        end
    end

    local meta = ZeitApi:extractArticleMeta(html)
    local title = meta.title or url
    local safe_title = util.getSafeFilename(title, nil, 100)
    local file_path = ("%s%s_%s.epub"):format(self.download_dir, os.date("%y-%m-%d"), safe_title)

    if lfs.attributes(file_path, "mode") == "file" then
        self:openDownloaded(file_path)
        return
    end

    local article_selectors = parseCommaSeparatedOption(self.article_selectors)
    local unwanted_selectors = parseCommaSeparatedOption(self.unwanted_selectors)
    local created = ZeitApi:createEpub(
        file_path, html, used_url, meta, self.include_images, title,
        #article_selectors > 0 and article_selectors or nil,
        #unwanted_selectors > 0 and unwanted_selectors or nil
    )
    if created then
        self:openDownloaded(file_path)
    end
end

--- Downloads the already-complete EPUB at epub_url (e.g. ZEIT's own
-- per-issue EPUB) as-is, without any HTML reduction. Meant to be called
-- from inside a Trapper:wrap() context, like fetchArticle().
function ZeitPlus:fetchDirectEpub(epub_url, title)
    local UI = require("ui/trapper")
    UI:info(_("Lade Ausgabe…"))

    local safe_title = util.getSafeFilename(title or epub_url, nil, 100)
    local file_path = ("%s%s_%s.epub"):format(self.download_dir, os.date("%y-%m-%d"), safe_title)
    if lfs.attributes(file_path, "mode") == "file" then
        self:openDownloaded(file_path)
        return
    end

    if ZeitApi:downloadFile(file_path, epub_url, self.cookies) then
        self:openDownloaded(file_path)
    end
end

function ZeitPlus:downloadArticleUrl(url)
    url = util.trim(url or "")
    if url == "" then return end
    if not url:match("^https?://") then
        UIManager:show(InfoMessage:new{ text = _("Bitte eine vollständige URL eingeben (Artikel, epaper.zeit.de-Ausgabe oder EPUB-Link).") })
        return
    end
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{ text = _("Bitte zuerst bei ZEIT+ anmelden.") })
        return
    end

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local ok, err = pcall(function()
            if url:match("%.epub$") then
                self:fetchDirectEpub(url, url:match("([^/]+)%.epub$"))
            elseif url:match("^https?://epaper%.zeit%.de/") then
                local _content_type, html = ZeitApi:loadPage(url, self.cookies, nil)
                local epub_url = ZeitApi:extractEpubLink(html)
                if not epub_url then
                    error(_("Auf dieser Seite wurde kein EPUB-Download-Link gefunden."))
                end
                self:fetchDirectEpub(epub_url, url:match("diezeit/([%d%.]+)"))
            else
                self:fetchArticle(url)
            end
        end)
        if not ok and err ~= ZeitApi.dismissed_error_code then
            UIManager:show(InfoMessage:new{ text = T(_("Fehler beim Herunterladen:\n%1"), tostring(err)) })
        end
    end)
end

function ZeitPlus:showAddArticleDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Link hinzufügen"),
        input = "",
        input_hint = "https://www.zeit.de/… oder epaper.zeit.de/…",
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

--- Builds the submenu entries for one overview page at url: fetches it
-- (RSS/Atom feed or, as fallback, an HTML overview page like
-- zeit.de/index) and returns one item per entry. An "article" entry
-- downloads that article (keeping the submenu open so several articles
-- can be picked in one go); an "index" entry (e.g. a weekly magazine
-- issue) drills into that page the same way.
function ZeitPlus:buildIndexMenu(url)
    local ok, result = pcall(function() return ZeitApi:fetchIndex(url, self.cookies) end)
    if not ok then
        return { { text = T(_("Fehler beim Laden:\n%1"), tostring(result)), enabled = false } }
    end
    if #result == 0 then
        return { { text = _("Keine Artikel gefunden."), enabled = false } }
    end

    -- Keep the two kinds separate so overview pages that mix categories
    -- (index entries) with articles end up in a sensible structure instead
    -- of one long mixed list: "Artikel" becomes its own submenu, categories
    -- stay as sibling submenus.
    local articles, indexes = {}, {}
    for _, entry in ipairs(result) do
        table.insert(entry.type == "index" and indexes or articles, entry)
    end

    local article_items = {}
    for idx, entry in ipairs(articles) do
        table.insert(article_items, {
            text = util.htmlEntitiesToUtf8(entry.title),
            mandatory = _("EPUB"),
            keep_menu_open = true,
            callback = function() self:downloadArticleUrl(entry.url) end,
        })
    end

    local items = {}
    if #indexes > 0 and #article_items > 0 then
        table.insert(items, {
            text = _("Artikel"),
            sub_item_table = article_items,
        })
    else
        items = article_items
    end
    for idx, entry in ipairs(indexes) do
        table.insert(items, {
            text = util.htmlEntitiesToUtf8(entry.title),
            sub_item_table_func = function() return self:buildIndexMenu(entry.url) end,
        })
    end
    return items
end

--- Builds the top-level "Stöbern" submenu: one entry per configured
-- source, each drilling into buildIndexMenu().
function ZeitPlus:buildSourceMenu()
    local sources = parseFeedSources(self.feed_sources)
    if #sources == 0 then
        return { { text = _("Bitte zuerst Quellen in den Einstellungen eintragen."), enabled = false } }
    end
    local items = {}
    for _, source in ipairs(sources) do
        table.insert(items, {
            text = source.name,
            sub_item_table_func = function() return self:buildIndexMenu(source.url) end,
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

--- Like selectorInputDialog(), but for multi-line content: Enter must stay
-- available to insert a newline, so unlike selectorInputDialog() no button
-- is marked is_enter_default and Save has to be tapped explicitly.
local function multilineInputDialog(title, hint, current, on_save)
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

--- Opens the multiline dialog for the "Name = URL" browsing sources.
function ZeitPlus:editFeedSources()
    multilineInputDialog(
        _("Quellen (eine pro Zeile: Name = URL)"),
        "Übersicht = https://www.zeit.de/index",
        self.feed_sources,
        function(text)
            text = util.trim(text)
            self.feed_sources = text ~= "" and text or defaultFeedSourcesText()
            self.updated = true
            self:onFlushSettings()
        end
    )
end

--- Opens the dialog for the CSS selectors of the article body.
function ZeitPlus:editArticleSelectors()
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
end

--- Opens the dialog for the CSS selectors of elements to drop from articles.
function ZeitPlus:editUnwantedSelectors()
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
end

function ZeitPlus:addToMainMenu(menu_items)
    menu_items.zeitplus = {
        text = _("ZEIT+"),
        callback = function()
            require("zeitplusui"):new(self):showHome()
        end,
    }
end

return ZeitPlus
