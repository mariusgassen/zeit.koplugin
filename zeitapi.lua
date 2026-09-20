--[[--
HTTP/login/EPUB backend for the ZEIT+ plugin.

Handles authenticating against a ZEIT+ account (meine.zeit.de), fetching an
article page with the resulting session cookies (so ZEIT+ content is
unlocked instead of showing the paywall teaser), and packaging the article
(with its images) into an EPUB that KOReader can open directly.

The HTTP/EPUB plumbing (cookie parsing, image fetching, EPUB assembly) is
adapted from KOReader's own newsdownloader.koplugin, which already
implements exactly this "login with cookies, fetch HTML, build EPUB"
pattern against KOReader's bundled libraries (LuaSocket, ffi/archiver,
htmlparser).

@module koplugin.zeitplus.zeitapi
]]

local ffiutil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local ZeitApi = {
    -- Can be set so HTTP requests are done under Trapper and are
    -- interruptible/show progress. See setTrapWidget().
    trap_widget = nil,
    dismissed_error_code = "Interrupted by user",

    login_url = "https://meine.zeit.de/anmelden?url=https%3A%2F%2Fwww.zeit.de%2Findex&entry_service=sonstige",

    -- Best-effort default selectors for the article body. ZEIT's markup
    -- can change over time; if extraction stops working, override these
    -- via the plugin settings (found by inspecting a logged-in article
    -- page in a desktop browser).
    default_article_selectors = {
        "article",
        "div.article-page",
        "div.article-body",
        "div[itemprop='articleBody']",
        "main",
        "div#main",
        "div#content",
    },
    default_unwanted_selectors = {
        "div.article__social",
        "div.article-header__service",
        "div.ad-container",
        "div.newsletter-signup",
        "div.comment-section",
        "aside",
        "figure.is-type-video",
        "div.fluid-width-video-wrapper",
        "div.youtube-wrap",
    },
    -- Strings that, if present, suggest the fetched page is still showing
    -- the paywall teaser rather than the full ZEIT+ article (i.e. the
    -- login session isn't unlocking premium content).
    paywall_markers = {
        "zeit%-plus%-cta",
        "Diesen Artikel weiterlesen",
        "Sie haben schon ein Abo",
        "paywall",
    },
}

-- ---------------------------------------------------------------------
-- Cookie helpers
-- From https://github.com/lunarmodules/luasocket/blob/master/samples/cookie.lua
-- ---------------------------------------------------------------------
local token_class = '[^%c%s%(%)%<%>%@%,%;%:%\\%"%/%[%]%?%=%{%}]'

local function unquote(t, quoted)
    local n = string.match(t, "%$(%d+)$")
    if n then n = tonumber(n) end
    if quoted[n] then return quoted[n]
    else return t end
end

local function parse_set_cookie(c, quoted, cookie_table)
    c = c .. ";$last=last;"
    local _unused, _unused2, n, v, i = string.find(c, "(" .. token_class ..
        "+)%s*=%s*(.-)%s*;%s*()")
    local cookie = {
        name = n,
        value = unquote(v, quoted),
        attributes = {},
    }
    while true do
        _unused, _unused2, n, v, i = string.find(c, "(" .. token_class ..
            "+)%s*=?%s*(.-)%s*;%s*()", i)
        if not n or n == "$last" then break end
        cookie.attributes[#cookie.attributes + 1] = { name = n, value = unquote(v, quoted) }
    end
    cookie_table[#cookie_table + 1] = cookie
end

local function split_set_cookie(s, cookie_table)
    cookie_table = cookie_table or {}
    if not s or s == "" then return cookie_table end
    local quoted = {}
    s = string.gsub(s, '"(.-)"', function(q)
        quoted[#quoted + 1] = q
        return "$" .. #quoted
    end)
    s = s .. ",$last="
    local i = 1
    while true do
        local _unused, _unused2, cookie, next_token
        _unused, _unused2, cookie, i, next_token = string.find(s, "(.-)%s*%,%s*()(" ..
            token_class .. "+)%s*=", i)
        if not next_token then break end
        parse_set_cookie(cookie, quoted, cookie_table)
        if next_token == "$last" then break end
    end
    return cookie_table
end

local function quote(s)
    if string.find(s, "[ %,%;]") then return '"' .. s .. '"'
    else return s end
end

local _empty = {}
local function build_cookie_header(cookies)
    local s = ""
    for i, v in ipairs(cookies or _empty) do
        if v.name then
            s = s .. v.name
            if v.value and v.value ~= "" then
                s = s .. "=" .. quote(v.value)
            end
        end
        if i < #cookies then s = s .. "; " end
    end
    return s
end

-- ---------------------------------------------------------------------
-- Raw HTTP
-- ---------------------------------------------------------------------

local DEFAULT_HEADERS = {
    ["user-agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 KOReader-ZeitPlus",
    ["accept-language"] = "de-DE,de;q=0.9",
}

local function mergedHeaders(cookies, extra_headers)
    local h = { ["cookie"] = build_cookie_header(cookies) }
    for k, v in pairs(DEFAULT_HEADERS) do h[k] = v end
    if extra_headers then
        for k, v in pairs(extra_headers) do h[k] = v end
    end
    return h
end

--- Performs a GET request and returns (ok, content_type, content_or_error, response_headers)
local function getUrlContent(url, cookies, timeout, maxtime, extra_headers)
    local parsed_url = socket_url.parse(url)
    if parsed_url.path then
        parsed_url.path = util.urlEncode(parsed_url.path, "/%%")
        url = socket_url.build(parsed_url)
    end

    if not timeout then timeout = 10 end
    local sink = {}
    socketutil:set_timeout(timeout, maxtime or 30)
    local request = {
        url = url,
        method = "GET",
        sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
        headers = mergedHeaders(cookies, extra_headers),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("ZeitApi: request interrupted:", status or code)
        return false, nil, code
    end
    if headers == nil then
        logger.warn("ZeitApi: no HTTP headers:", status or code or "network unreachable")
        return false, nil, _("Network or remote server unavailable")
    end
    if headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if content_length and #content ~= content_length then
            return false, nil, _("Incomplete content received")
        end
    end
    if code >= 400 then
        logger.warn("ZeitApi: HTTP error:", status or code)
        return false, nil, tostring(status or code)
    end

    return true, headers["content-type"], content, headers
end

--- Logs into meine.zeit.de with the given credentials.
-- Returns (ok, cookies_or_error_message).
function ZeitApi:login(username, password)
    local body = "username=" .. util.urlEncode(username) .. "&password=" .. util.urlEncode(password)
    socketutil:set_timeout(10, 30)
    local request = {
        method = "POST",
        url = self.login_url,
        headers = (function()
            local h = mergedHeaders(nil, { ["content-type"] = "application/x-www-form-urlencoded" })
            h["content-length"] = tostring(#body)
            return h
        end)(),
        source = ltn12.source.string(body),
        sink = ltn12.sink.table({}),
    }
    local code, headers = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if headers == nil then
        return false, _("Network or remote server unavailable")
    end
    local cookies = split_set_cookie(headers["set-cookie"], {})
    if #cookies == 0 then
        return false, _("Login failed: server did not return a session. Please check your ZEIT+ email and password.")
    end
    logger.dbg("ZeitApi:login code:", code, "cookies:", cookies)
    return true, cookies
end

function ZeitApi:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function ZeitApi:resetTrapWidget()
    self.trap_widget = nil
end

--- Fetches a page, using Trapper (interruptible, shows progress) if a trap
-- widget has been set, otherwise doing a plain blocking request.
function ZeitApi:loadPage(url, cookies, extra_headers)
    local completed, success, content_type, content
    if self.trap_widget then
        local Trapper = require("ui/trapper")
        completed, success, content_type, content = Trapper:dismissableRunInSubprocess(function()
            return getUrlContent(url, cookies, 30, 60, extra_headers)
        end, self.trap_widget)
        if not completed then
            error(self.dismissed_error_code)
        end
    else
        success, content_type, content = getUrlContent(url, cookies, 10, 60, extra_headers)
    end
    if not success then
        error(content)
    end
    return content_type, content
end

--- Returns true if the given article HTML looks like it's still showing
-- the paywall teaser rather than the unlocked ZEIT+ article.
function ZeitApi:isLikelyPaywalled(html)
    for _, marker in ipairs(self.paywall_markers) do
        if html:find(marker) then
            return true
        end
    end
    return false
end

--- Candidate URLs that should return the *full* single-page article text
-- instead of the teaser/pagination variant zeit.de normally serves:
-- ZEIT's "Komplettansicht" path suffix and its legacy query flag.
function ZeitApi:articleVariants(url)
    local base = url:match("^([^?#]+)") or url
    local variants = {}
    if not base:match("/komplettansicht/?$") then
        variants[#variants + 1] = base .. "/komplettansicht"
    end
    variants[#variants + 1] = url .. (url:find("%?") and "&" or "?") .. "komplettansicht=1"
    return variants
end

--- Loads an article page, preferring ZEIT's "Komplettansicht" (full-text
-- single page) variants so the whole article lands in the EPUB instead of
-- only the first teaser part. Falls back to the original url when none of
-- the variants loads or still shows the paywall. Returns (used_url,
-- content_type, html).
function ZeitApi:loadArticlePage(url, cookies, extra_headers)
    local plain = url:match("^([^?#]+)") or url
    if plain:match("/komplettansicht/?$") then
        local content_type, content = self:loadPage(url, cookies, extra_headers)
        return url, content_type, content
    end
    for _, candidate in ipairs(self:articleVariants(url)) do
        local ok, content_type, content = pcall(self.loadPage, self, candidate, cookies, extra_headers)
        if ok and content:find("<%s*article[%s>]") and not self:isLikelyPaywalled(content) then
            logger.dbg("ZeitApi: using article variant:", candidate)
            return candidate, content_type, content
        end
    end
    local content_type, content = self:loadPage(url, cookies, extra_headers)
    return url, content_type, content
end

local function extractMeta(html, property)
    local pattern1 = '<meta[^>]-property="' .. property .. '"[^>]-content="([^"]*)"'
    local pattern2 = '<meta[^>]-content="([^"]*)"[^>]-property="' .. property .. '"'
    return html:match(pattern1) or html:match(pattern2)
end

local function extractMetaName(html, name)
    local pattern1 = '<meta[^>]-name="' .. name .. '"[^>]-content="([^"]*)"'
    local pattern2 = '<meta[^>]-content="([^"]*)"[^>]-name="' .. name .. '"'
    return html:match(pattern1) or html:match(pattern2)
end

--- Extracts a small set of metadata (title, author, published date) from
-- the raw page head, before the HTML gets reduced to the article body.
function ZeitApi:extractArticleMeta(html)
    return {
        title = extractMeta(html, "og:title") or html:match([[<title[^>]*>(.-)</title>]]),
        author = extractMetaName(html, "author"),
        published = extractMeta(html, "article:published_time"),
    }
end

-- ---------------------------------------------------------------------
-- Direct EPUB download (e.g. the officially pre-built EPUB ZEIT offers
-- per print issue via epaper.zeit.de, served from media-delivery.zeit.de)
-- ---------------------------------------------------------------------

--- Finds the first media-delivery.zeit.de EPUB link in html, e.g. the
-- one behind an epaper.zeit.de issue page's "EPUB" download button.
function ZeitApi:extractEpubLink(html)
    return html:match('href="(https?://media%-delivery%.zeit%.de/[^"]-%.epub)"')
        or html:match("href='(https?://media%-delivery%.zeit%.de/[^']-%.epub)'")
        or html:match("(https?://media%-delivery%.zeit%.de/[^%s\"'<>]-%.epub)")
end

--- Downloads url's raw bytes to file_path as-is (no HTML reduction),
-- for an already-complete EPUB. Raises an error (to be caught with
-- pcall by the caller) on network failure.
function ZeitApi:downloadFile(file_path, url, cookies)
    local _content_type, content = self:loadPage(url, cookies, nil)
    local file_path_tmp = file_path .. ".tmp"
    local f = io.open(file_path_tmp, "wb")
    if not f then
        return false
    end
    f:write(content)
    f:close()
    os.rename(file_path_tmp, file_path)
    return true
end

-- ---------------------------------------------------------------------
-- Feed parsing (RSS 2.0 / Atom)
-- ---------------------------------------------------------------------

local function feedTrim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stripCDATA(s)
    if not s then return s end
    local inner = s:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$")
    return inner or s
end

local function extractFeedTag(block, tag)
    local content = block:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    if content then
        return feedTrim(stripCDATA(content))
    end
    return nil
end

local function extractAtomLink(block)
    return block:match('<link[^>]-rel="alternate"[^>]-href="([^"]*)"')
        or block:match('<link[^>]-href="([^"]*)"[^>]-rel="alternate"')
        or block:match('<link[^>]-href="([^"]*)"[^>]*/?>')
end

--- Parses an RSS 2.0 or Atom feed body into a list of
-- { title, link, pubDate } entries (pubDate may be nil).
function ZeitApi:parseFeed(xml)
    local items = {}
    for block in xml:gmatch("<item[^>]*>(.-)</item>") do
        local title = extractFeedTag(block, "title")
        local link = extractFeedTag(block, "link")
        local pubdate = extractFeedTag(block, "pubDate")
        if title and link and link ~= "" then
            table.insert(items, { title = title, link = feedTrim(link), pubDate = pubdate })
        end
    end
    if #items == 0 then
        for block in xml:gmatch("<entry[^>]*>(.-)</entry>") do
            local title = extractFeedTag(block, "title")
            local link = extractAtomLink(block)
            local pubdate = extractFeedTag(block, "updated") or extractFeedTag(block, "published")
            if title and link and link ~= "" then
                table.insert(items, { title = title, link = feedTrim(link), pubDate = pubdate })
            end
        end
    end
    return items
end

-- ---------------------------------------------------------------------
-- Index/overview pages (e.g. zeit.de/index, zeit.de/exklusive-zeit-artikel,
-- a weekly zeit.de/<year>/<issue>/index) - scraped as a fallback for pages
-- that aren't a feed, by picking out links that look like articles or
-- like a further index/overview page to browse into.
-- ---------------------------------------------------------------------

local function resolveZeitUrl(href)
    if href:sub(1, 2) == "//" then
        return "https:" .. href
    elseif href:sub(1, 1) == "/" then
        return "https://www.zeit.de" .. href
    end
    return href
end

local function stripQueryAndFragment(url)
    return url:match("^([^?#]+)") or url
end

--- Returns the deduplicated { href, text } links to zeit.de found in html.
local function extractZeitLinks(html)
    local seen, out = {}, {}
    for attrs, text in html:gmatch("<a%s+([^>]-)>(.-)</a>") do
        local href = attrs:match('href="([^"]*)"') or attrs:match("href='([^']*)'")
        if href and href ~= "" and href:sub(1, 1) ~= "#" then
            href = resolveZeitUrl(href)
            if href:match("^https?://www%.zeit%.de") then
                href = stripQueryAndFragment(href)
                if not seen[href] then
                    -- Drop <script>/<noscript> JSON-LD blobs and <style> the
                    -- teaser anchors contain (they would otherwise show up
                    -- as huge garbage menu titles).
                    local clean = text
                    while clean:find("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]>")
                        or clean:find("<[Nn][Oo][Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Nn][Oo][Ss][Cc][Rr][Ii][Pp][Tt]>")
                        or clean:find("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]>") do
                        clean = clean:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
                        clean = clean:gsub("<[Nn][Oo][Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Nn][Oo][Ss][Cc][Rr][Ii][Pp][Tt]>", "")
                        clean = clean:gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]>", "")
                    end
                    local clean_text = feedTrim((clean:gsub("<[^>]+>", " "):gsub("%s+", " ")))
                    if clean_text ~= "" then
                        seen[href] = true
                        table.insert(out, { href = href, text = clean_text })
                    end
                end
            end
        end
    end
    return out
end

--- For weekly-issue links (zeit.de/2026/40/index) returns a readable
-- "Ausgabe 40/2026" label, since their anchor only contains a JSON-LD
-- cover-image script. Returns nil for any other URL.
local function issueLabel(href)
    local year, issue = href:match("^https?://www%.zeit%.de/(%d%d%d%d)/(%d+)/index/?$")
    if year and issue then
        return _("Ausgabe ") .. issue .. "/" .. year
    end
    return nil
end

--- Classifies a zeit.de URL as "article" (has a date/issue segment in its
-- path, e.g. /politik/2025-09/... or /2025/38/...) or "index" (a further
-- overview page to browse into, i.e. ends in /index). Anything else
-- (navigation, footer, login/newsletter/etc. links) is ignored.
local function classifyZeitLink(href)
    if href:match("/index/?$") then
        return "index"
    end
    if href:match("/%d%d%d%d%-%d%d/") or href:match("/%d%d%d%d/%d+/") then
        return "article"
    end
    return nil
end

--- Scrapes an overview page into a list of { type, title, url } entries,
-- type being "article" or "index".
function ZeitApi:parseIndexHtml(html)
    local out = {}
    for _, link in ipairs(extractZeitLinks(html)) do
        local kind = classifyZeitLink(link.href)
        if kind then
            local title = link.text
            if kind == "index" then
                title = issueLabel(link.href) or title
            end
            table.insert(out, { type = kind, title = title, url = link.href })
        end
    end
    return out
end

--- Fetches url and returns its entries as a list of { type, title, url }
-- (type "article" or "index"), trying an RSS/Atom feed parse first and
-- falling back to scraping it as an HTML overview page. Raises an error
-- (to be caught with pcall by the caller) on network failure.
function ZeitApi:fetchIndex(url, cookies)
    local _content_type, content = self:loadPage(url, cookies, nil)
    local feed_items = self:parseFeed(content)
    if #feed_items > 0 then
        local out = {}
        for _, item in ipairs(feed_items) do
            table.insert(out, { type = "article", title = item.title, url = item.link })
        end
        return out
    end
    return self:parseIndexHtml(content)
end

-- ---------------------------------------------------------------------
-- HTML reduction (selecting the article body, dropping unwanted nodes)
-- ---------------------------------------------------------------------

local function userOrDefault(user, default)
    if type(user) == "table" and next(user) ~= nil then
        return user
    end
    return default
end

local function selectMatchingNode(root_node, user_selectors, default_selectors)
    local selectors = userOrDefault(user_selectors, default_selectors)
    for _, selector in ipairs(selectors) do
        local ok, nodes = pcall(function() return root_node:select(selector) end)
        if ok and nodes then
            for _, node in ipairs(nodes) do
                if node:getcontent() then
                    return node
                end
            end
        end
    end
    return root_node
end

local function removeSubstring(str, substr)
    local iter = 1
    local i, j
    repeat
        i, j = string.find(str, substr, iter, true)
        if i then
            str = string.sub(str, 1, i - 1) .. string.sub(str, j + 1, -1)
            iter = i
        end
    until not i
    return str
end

local function removeUnwantedNodes(wanted_node, user_selectors, default_selectors)
    local selectors = userOrDefault(user_selectors, default_selectors)
    local node_content = wanted_node:getcontent()
    for _, selector in ipairs(selectors) do
        local ok, unwanted_nodes = pcall(function() return wanted_node:select(selector) end)
        if ok and unwanted_nodes then
            for _, unwanted_node in ipairs(unwanted_nodes) do
                node_content = removeSubstring(node_content, unwanted_node:gettext())
            end
        end
    end
    return node_content
end

function ZeitApi:reduceHTML(input_html, article_selectors, unwanted_selectors)
    local htmlparser = require("htmlparser")
    local root = htmlparser.parse(input_html, 5000)
    local wanted_node = selectMatchingNode(root, article_selectors, self.default_article_selectors)
    local cleaned_inner_html = removeUnwantedNodes(wanted_node, unwanted_selectors, self.default_unwanted_selectors)
    return "<!DOCTYPE html><html><head></head><body>" .. cleaned_inner_html .. "</body></html>"
end

-- ---------------------------------------------------------------------
-- EPUB assembly (adapted from newsdownloader.koplugin/epubdownloadbackend.lua)
-- ---------------------------------------------------------------------

local ext_to_mimetype = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    svg = "image/svg+xml",
    webp = "image/webp",
}

--- Builds an EPUB at epub_path from the article HTML fetched from url.
-- meta: { title, author, published } as returned by extractArticleMeta().
function ZeitApi:createEpub(epub_path, html, url, meta, include_images, message, article_selectors, unwanted_selectors)
    local UI = require("ui/trapper")
    local base_url = socket_url.parse(url)

    local page_title = (meta and meta.title) or html:match([[<title[^>]*>(.-)</title>]]) or url
    page_title = util.htmlEntitiesToUtf8(page_title)

    local cre = require("libs/libkoreader-cre")
    local body_html = self:reduceHTML(html, article_selectors, unwanted_selectors)

    -- Prepend a small header with title/byline/date so it reads naturally
    -- as part of the article.
    local header_parts = { string.format("<h1>%s</h1>", page_title) }
    if meta and (meta.author or meta.published) then
        local byline_bits = {}
        if meta.author then table.insert(byline_bits, meta.author) end
        if meta.published then table.insert(byline_bits, meta.published:sub(1, 10)) end
        table.insert(header_parts, string.format("<p><em>%s</em></p>", table.concat(byline_bits, " – ")))
    end
    body_html = body_html:gsub("<body>", "<body>" .. table.concat(header_parts))

    body_html = cre.getBalancedHTML(body_html, 0x0)

    local images = {}
    local seen_images = {}
    local imagenum = 1
    local cover_imgid = nil

    local function isRelative(url_string)
        local parsed = socket_url.parse(url_string)
        return parsed and parsed.scheme == nil
    end

    local processImg = function(img_tag)
        local src = img_tag:match([[src="([^"]*)"]])
        if not src or src == "" or src:sub(1, 5) == "data:" then
            return nil
        end
        if src:sub(1, 2) == "//" then
            src = "https:" .. src
        elseif isRelative(src) then
            src = socket_url.absolute(base_url, src)
        end
        local cur_image = seen_images[src]
        if not cur_image then
            local src_ext = src:find("?") and src:match("(.-)%?") or src
            local ext = (src_ext:match(".*%.(%S%S%S?%S?%S?)$") or ""):lower()
            local imgid = string.format("img%05d", imagenum)
            local imgpath = ext ~= "" and string.format("images/%s.%s", imgid, ext) or string.format("images/%s", imgid)
            local width = tonumber(img_tag:match([[width="([^"]*)"]]))
            local height = tonumber(img_tag:match([[height="([^"]*)"]]))
            cur_image = {
                imgid = imgid,
                imgpath = imgpath,
                src = src,
                mimetype = ext_to_mimetype[ext] or "",
                width = width,
                height = height,
            }
            table.insert(images, cur_image)
            seen_images[src] = cur_image
            if not cover_imgid and width and width > 50 and height and height > 50 then
                cover_imgid = imgid
            end
            imagenum = imagenum + 1
        end
        local style_props = {}
        if cur_image.width then table.insert(style_props, string.format("width: %spx", cur_image.width)) end
        if cur_image.height then table.insert(style_props, string.format("height: %spx", cur_image.height)) end
        return string.format([[<img src="%s" style="%s" alt=""/>]], cur_image.imgpath, table.concat(style_props, "; "))
    end
    body_html = body_html:gsub("(<%s*img [^>]*>)", processImg)

    if not include_images then
        body_html = body_html:gsub("<%s*img [^>]*>", "")
    end

    UI:info(T(_("%1\n\nErstelle EPUB…"), message))
    local Archiver = require("ffi/archiver")
    local epub = Archiver.Writer:new{}
    local epub_path_tmp = epub_path .. ".tmp"
    if not epub:open(epub_path_tmp, "epub") then
        return false
    end

    local mtime = os.time()

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    local content_opf_parts = {}
    local meta_cover = "<!-- no cover image -->"
    if include_images and cover_imgid then
        meta_cover = string.format([[<meta name="cover" content="%s"/>]], cover_imgid)
    end
    local dc_creator = ""
    if meta and meta.author then
        dc_creator = string.format("<dc:creator>%s</dc:creator>", meta.author)
    end
    table.insert(content_opf_parts, string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:publisher>ZEIT+ (via KOReader)</dc:publisher>
    %s
    %s
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
]], page_title, dc_creator, meta_cover))
    if include_images then
        for _, img in ipairs(images) do
            table.insert(content_opf_parts, string.format([[    <item id="%s" href="%s" media-type="%s"/>%s]], img.imgid, img.imgpath, img.mimetype, "\n"))
        end
    end
    table.insert(content_opf_parts, [[
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]])
    epub:addFileFromMemory("OEBPS/content.opf", table.concat(content_opf_parts), mtime)

    epub:addFileFromMemory("OEBPS/stylesheet.css", "/* Empty */\n", mtime)

    epub:addFileFromMemory("OEBPS/toc.ncx", string.format([[
<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="zeitplus"/>
    <meta name="dtb:depth" content="0"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1"><navLabel><text>%s</text></navLabel><content src="content.html"/></navPoint>
  </navMap>
</ncx>
]], page_title, page_title), mtime)

    epub:addFileFromMemory("OEBPS/content.html", body_html, mtime)

    collectgarbage()
    collectgarbage()

    -- Downloaded sequentially rather than concurrently: KOReader's
    -- httpasync module (used for this in newsdownloader.koplugin) isn't
    -- present in every KOReader version/build. Slower for image-heavy
    -- articles, but works everywhere.
    local cancelled = false
    if include_images and #images > 0 then
        local total = #images
        local failed_images = {}
        local time_prev = time.now()
        for inum, img in ipairs(images) do
            local ok, _content_type, content = getUrlContent(img.src, nil, 10, 30)
            if ok then
                local no_compression = img.mimetype ~= "image/svg+xml"
                epub:addFileFromMemory("OEBPS/" .. img.imgpath, content, no_compression, mtime)
            else
                logger.info("ZeitApi: failed fetching image:", img.src, content)
                table.insert(failed_images, inum)
            end

            if time.to_ms(time.since(time_prev)) > 1000 or inum == total then
                time_prev = time.now()
                local errors = #failed_images
                local prefix = message and message ~= "" and message .. "\n\n" or ""
                local go_on
                if errors > 0 then
                    go_on = UI:info(prefix .. T(_("Lade Bilder… %1 / %2 (%3 Fehler)"), inum, total, errors), true)
                else
                    go_on = UI:info(prefix .. T(_("Lade Bilder… %1 / %2"), inum, total), true)
                end
                if not go_on then
                    cancelled = true
                    break
                end
            end
        end
    end

    if cancelled then
        UI:info(_("Abgebrochen. Räume auf…"))
    else
        UI:info(T(_("%1\n\nEPUB wird gepackt…"), message))
    end
    epub:close()

    if cancelled then
        if lfs.attributes(epub_path_tmp, "mode") == "file" then
            os.remove(epub_path_tmp)
        end
        return false
    end

    os.rename(epub_path_tmp, epub_path)
    collectgarbage()
    collectgarbage()
    return true
end

return ZeitApi
