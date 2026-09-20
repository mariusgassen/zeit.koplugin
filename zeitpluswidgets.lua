--[[--
Touch-driven full-screen app widgets for the ZEIT+ plugin.

KOReader's Menu cannot render images, brand colors or rich headers, so the
app's two flagship screens are custom widgets instead (the same trade
BookOrbit makes with its cover-grid dashboard):

  * Home – branded header (ZEIT+ wordmark, session pill, account line)
           plus the tappable action rows (sources, library, link, settings).
  * Grid – "Meine Artikel" as a cover grid (2/3 columns), covers from the
           .cover.jpg we save next to each downloaded EPUB, or a title
           tile placeholder when the image is missing.

Both are full-screen InputContainers whose tap/hold targets are remembered
as screen rectangles during build() and resolved in onTapInput/onHoldInput.
Pagination (‹ Seite k von n ›) keeps the layouts within the screen.

The widgets talk to a tiny controller interface provided by ZeitPlusUI:

  buildHomeData()      -> { header = {title, pill, pill_color, subtitle},
                            rows   = { {text, bold, mandatory, callback}, ... } }
  buildLibrary()       -> { {title, date, path, cover}, ... } newest first
  quit()               -> close the app back to the file manager
  openBook(path)       -> open an EPUB in the reader
  confirmDelete(path, title)

@module koplugin.zeitplus.zeitpluswidgets
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = require("device").screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local ZeitPlusWidgets = {}

local PAD = 20

-- ZEIT og:image teasers are 1200x630 (landscape); used to fit them into a
-- square tile without distortion.
local OG_IMAGE_ASPECT = 1200 / 630

local function y_gap()
    return Size.span.vertical_default
end

local function textH(face)
    return TextWidget:new{ text = "Xgy", face = face }:getSize().h
end

local function smallFace()
    return Font:getFace("x_smallinfofont", 16)
end

--- Base class: a full-screen page that remembers its tap targets.
local AppPage = InputContainer:extend{
    ui = nil,
    page = 1,
    zones = nil,
}

function AppPage:init()
    self.zones = {}
    self.page = 1
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    InputContainer.init(self)
    self:build()
end

function AppPage:_addZone(x0, y0, x1, y1, action, hold_action)
    table.insert(self.zones, {
        x0 = x0, y0 = y0, x1 = x1, y1 = y1,
        action = action, hold_action = hold_action,
    })
end

function AppPage:_zoneAt(x, y)
    for _, zone in ipairs(self.zones) do
        if x >= zone.x0 and x <= zone.x1 and y >= zone.y0 and y <= zone.y1 then
            return zone
        end
    end
    return nil
end

function AppPage:onTapInput(ges)
    local zone = self:_zoneAt(ges.pos.x, ges.pos.y)
    if zone and zone.action then
        zone.action()
    end
    return true
end

function AppPage:onHoldInput(ges)
    local zone = self:_zoneAt(ges.pos.x, ges.pos.y)
    if zone and zone.hold_action then
        zone.hold_action()
    end
    return true
end

--- Rebuilds the widget tree in place (used after data changes).
function AppPage:refresh()
    self.zones = {}
    self:build()
    UIManager:setDirty(self, "ui")
end

--- Footer pagination bar ("< Seite k von n >"), pushed to the bottom of the
-- screen via a flexible spacer. Registers the previous/next tap zones.
function AppPage:_addPagination(vgroup, y_used, y_free, pages, label)
    local face = Font:getFace("x_smallinfofont", 18)
    local footer_h = PAD + textH(face) + y_gap()
    local plain = pages and pages > 1
    local vspan = math.max(0, y_free - y_used - footer_h)
    table.insert(vgroup, VerticalSpan:new{ width = vspan })
    local y0 = y_used + vspan
    local arrow_w = math.floor(Screen:getWidth() / 3)
    if plain then
        self:_addZone(0, y0, arrow_w, y0 + footer_h, function()
            if self.page > 1 then
                self.page = self.page - 1
                self:refresh()
            end
        end)
        self:_addZone(Screen:getWidth() - arrow_w, y0, Screen:getWidth(), y0 + footer_h, function()
            if self.page < pages then
                self.page = self.page + 1
                self:refresh()
            end
        end)
    end
    local footer = FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new{ w = Screen:getWidth(), h = footer_h },
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = footer_h },
            HorizontalGroup:new{
                align = "center",
                TextWidget:new{ text = plain and "<" or " ", face = face, fgcolor = Blitbuffer.COLOR_GRAY },
                HorizontalSpan:new{ width = Size.span.horizontal_default },
                TextWidget:new{ text = label, face = face },
                HorizontalSpan:new{ width = Size.span.horizontal_default },
                TextWidget:new{ text = plain and ">" or " ", face = face, fgcolor = Blitbuffer.COLOR_GRAY },
            },
        },
    }
    table.insert(vgroup, footer)
    return footer_h
end

--- Layout helper: a full-width row with a label on the left and an optional
-- muted value on the right, wrapped for band-based tap zones.
function AppPage:_addRow(vgroup, row, content_w, row_h, y_gap_h)
    local face = Font:getFace("ffont", 22)
    local label = TextWidget:new{ text = row.text, face = face, bold = row.bold }
    local label_w = label:getSize().w
    local label_span = label_w + 2 * Size.padding.small
    local inner_w = math.max(1, content_w - PAD - label_span - PAD)
    local mandatory
    if row.mandatory and row.mandatory ~= "" then
        local m_face = Font:getFace("x_smallinfofont", 18)
        mandatory = RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = row_h },
            TextWidget:new{ text = row.mandatory, face = m_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        }
    else
        mandatory = HorizontalSpan:new{ width = PAD }
    end
    local row_widget = FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        dimen = Geom:new{ w = content_w, h = row_h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = PAD },
            label,
            HorizontalSpan:new{ width = math.max(1, content_w - PAD - label_w - PAD - (row.mandatory and inner_w or 0)) },
            mandatory,
            HorizontalSpan:new{ width = PAD },
        },
    }
    table.insert(vgroup, row_widget)
    table.insert(vgroup, VerticalSpan:new{ width = y_gap_h })
end

-- ---------------------------------------------------------------------
-- Home
-- ---------------------------------------------------------------------

ZeitPlusWidgets.Home = AppPage:extend{}

function ZeitPlusWidgets.Home:build()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local content_w = screen_w - 2 * PAD
    local data = self.ui:buildHomeData()
    local header = data.header
    local rows = data.rows

    local vgroup = VerticalGroup:new{ align = "left" }
    table.insert(vgroup, VerticalSpan:new{ width = PAD })
    local y = PAD

    -- Wordmark + session pill, with a small "x" close affordance top-right.
    local word_face = Font:getFace("cfont", math.floor(screen_w / 16))
    local wordmark = TextWidget:new{ text = header.title, face = word_face, bold = true }
    local word_h = wordmark:getSize().h

    local close_face = Font:getFace("cfont", math.floor(word_h * 0.8))
    local close_w = textH(close_face)
    local close_zone_w = close_w + 2 * PAD
    self:_addZone(screen_w - close_zone_w, 0, screen_w, word_h + PAD, function()
        self.ui:quit()
    end)

    local pill_face = Font:getFace("x_smallinfofont", 18)
    local pill_text = TextWidget:new{
        text = header.pill, face = pill_face, bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    local pill = FrameContainer:new{
        margin = 0, padding = Size.padding.small, bordersize = 0,
        background = header.pill_color,
        pill_text,
    }
    local header_h = math.max(word_h + 2 * PAD, pill:getSize().h + 2 * PAD)

    table.insert(vgroup, FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        dimen = Geom:new{ w = content_w, h = header_h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = PAD },
            wordmark,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = math.max(1, content_w - wordmark:getSize().w - Size.span.horizontal_default - close_zone_w - 2 * PAD) },
                pill,
                HorizontalSpan:new{ width = Size.padding.default },
            },
            HorizontalSpan:new{ width = PAD },
        },
    })
    y = y + header_h + y_gap()

    -- Account line.
    if header.subtitle and header.subtitle ~= "" then
        table.insert(vgroup, TextWidget:new{
            text = header.subtitle,
            face = Font:getFace("x_smallinfofont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(vgroup, VerticalSpan:new{ width = y_gap() })
        y = y + textH(smallFace()) + y_gap()
    end

    -- Faint separator.
    table.insert(vgroup, FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        dimen = Geom:new{ w = content_w, h = 1 },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    })
    table.insert(vgroup, VerticalSpan:new{ width = y_gap() })
    y = y + 1 + y_gap()

    -- Action rows, paginated if they overflow the screen.
    local face = Font:getFace("ffont", 22)
    local row_h = textH(face) + 2 * Size.padding.small
    local row_pitch = row_h + y_gap()
    local footer_h = PAD + textH(Font:getFace("x_smallinfofont", 18)) + y_gap()
    local avail = screen_h - y - footer_h - PAD
    local per_page = math.max(1, math.floor(avail / row_pitch))
    local pages = math.max(1, math.ceil(#rows / per_page))
    if pages < 1 then pages = 1 end
    if self.page > pages then self.page = pages end
    local first = (self.page - 1) * per_page + 1
    local last = math.min(#rows, first + per_page - 1)

    for idx = first, last do
        local row = rows[idx]
        local y0 = y
        if row.callback then
            self:_addZone(0, y0, screen_w, y0 + row_pitch, row.callback)
        end
        self:_addRow(vgroup, row, content_w, row_h, y_gap())
        y = y + row_pitch
    end

    self:_addPagination(vgroup, y, screen_h - PAD, pages,
        _("Seite %1 von %2"):format(self.page, pages))
end

-- ---------------------------------------------------------------------
-- Meine Artikel cover grid
-- ---------------------------------------------------------------------

ZeitPlusWidgets.Grid = AppPage:extend{}

local function fitCover(entry, inner_w, cover_h)
    if entry.cover and lfs.attributes(entry.cover, "mode") == "file"
            and (lfs.attributes(entry.cover, "size") or 0) > 0 then
        local disp_w = inner_w
        local disp_h = inner_w / OG_IMAGE_ASPECT
        if disp_h > cover_h then
            disp_h = cover_h
            disp_w = cover_h * OG_IMAGE_ASPECT
        end
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = entry.cover, width = disp_w, height = disp_h,
        })
        if ok then
            return CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = cover_h },
                img,
            }
        end
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = cover_h },
        TextBoxWidget:new{
            text = entry.title,
            face = Font:getFace("cfont", 18),
            alignment = "center",
            width = inner_w - 2 * Size.padding.small,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
end

function ZeitPlusWidgets.Grid:build()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local content_w = screen_w - 2 * PAD
    local entries = self.ui:buildLibrary()

    local vgroup = VerticalGroup:new{ align = "left" }
    table.insert(vgroup, VerticalSpan:new{ width = PAD })
    local y = PAD

    -- Header: back "<", title, count.
    local head_face = Font:getFace("cfont", 26)
    local back_w = textH(head_face)
    self:_addZone(0, 0, back_w + 2 * PAD, back_w + 2 * PAD, function()
        self.ui:closeGrid()
    end)
    table.insert(vgroup, FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        dimen = Geom:new{ w = content_w, h = back_w + PAD },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = PAD },
            TextWidget:new{ text = "<", face = head_face, fgcolor = Blitbuffer.COLOR_GRAY },
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            TextWidget:new{ text = _("Meine Artikel"), face = head_face, bold = true },
            HorizontalSpan:new{ width = math.max(1, content_w - back_w - textH(head_face) - 3 * PAD - 2 * Size.span.horizontal_default) },
            TextWidget:new{ text = tostring(#entries), face = Font:getFace("x_smallinfofont", 16), fgcolor = Blitbuffer.COLOR_DARK_GRAY },
            HorizontalSpan:new{ width = PAD },
        },
    })
    y = y + back_w + PAD

    if #entries == 0 then
        table.insert(vgroup, TextWidget:new{
            text = _("Noch keine Artikel heruntergeladen."),
            face = Font:getFace("x_smallinfofont", 18),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
        self:_addPagination(vgroup, y, screen_h - PAD, 1, _("Meine Artikel"))
        return
    end

    -- Grid metrics.
    local cols = screen_w >= 1000 and 3 or 2
    local gap = math.min(Size.span.horizontal_default, 8)
    local card_w = math.floor((content_w - (cols - 1) * gap) / cols)
    local cap_face = Font:getFace("x_smallinfofont", 16)
    local caption_h = textH(cap_face) + textH(Font:getFace("x_smallinfofont", 14)) + y_gap()
    local footer_h = PAD + textH(Font:getFace("x_smallinfofont", 18)) + y_gap()
    local avail = screen_h - y - footer_h - PAD
    local racks = math.max(1, math.floor((avail + y_gap()) / (card_w + caption_h + 2 * y_gap())))
    local card_h = math.max(1, math.floor((avail - (racks - 1) * y_gap()) / racks))
    local cover_h = math.max(40, card_h - caption_h)
    local per_page = racks * cols
    local pages = math.max(1, math.ceil(#entries / per_page))
    if self.page > pages then self.page = pages end
    local first = (self.page - 1) * per_page + 1
    local last = math.min(#entries, first + per_page - 1)

    local rack_y = y
    local rack_cells = {}
    local rack_idx = 0
    local function flushRack()
        if #rack_cells == 0 then return end
        local cells = { HorizontalSpan:new{ width = PAD } }
        for i, cell in ipairs(rack_cells) do
            if i > 1 then table.insert(cells, HorizontalSpan:new{ width = gap }) end
            table.insert(cells, cell)
        end
        table.insert(cells, HorizontalSpan:new{ width = PAD })
        table.insert(vgroup, HorizontalGroup:new{ align = "center", unpack(cells) })
        table.insert(vgroup, VerticalSpan:new{ width = y_gap() })
        rack_cells = {}
    end
    for idx = first, last do
        local col = (idx - first) % cols
        local rack = math.floor((idx - first) / cols)
        if rack ~= rack_idx then
            flushRack()
            rack_idx = rack
            rack_y = rack_y + card_h + y_gap()
        end
        local x0 = PAD + col * (card_w + gap)
        local cover = FrameContainer:new{
            margin = 0, padding = 0, bordersize = 0,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = card_w, h = cover_h },
            fitCover(entries[idx], card_w, cover_h),
        }
        local title_line = TextBoxWidget:new{
            text = entries[idx].title,
            face = cap_face,
            width = card_w,
            height = textH(cap_face) + 1,
            height_overflow_show_ellipsis = true,
        }
        local caption = VerticalGroup:new{ align = "left",
            title_line,
            TextWidget:new{
                text = entries[idx].date,
                face = Font:getFace("x_smallinfofont", 14),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
        self:_addZone(x0, rack_y, x0 + card_w, rack_y + card_h, function()
            self.ui:openBook(entries[idx].path)
        end, function()
            self.ui:confirmDelete(entries[idx].path, entries[idx].title)
        end)
        table.insert(rack_cells, VerticalGroup:new{ align = "left",
            cover,
            caption,
        })
    end
    flushRack()

    self:_addPagination(vgroup, rack_y, screen_h - PAD, pages,
        _("Seite %1 von %2"):format(self.page, pages))
end

return ZeitPlusWidgets