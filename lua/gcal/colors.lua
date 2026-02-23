local config = require("gcal.config")

local M = {}

local palette = {
  { bg = "#7986cb", fg = "#ffffff" },
  { bg = "#33b679", fg = "#ffffff" },
  { bg = "#8e24aa", fg = "#ffffff" },
  { bg = "#e67c73", fg = "#ffffff" },
  { bg = "#f6bf26", fg = "#1a1a1a" },
  { bg = "#f4511e", fg = "#ffffff" },
  { bg = "#039be5", fg = "#ffffff" },
  { bg = "#616161", fg = "#ffffff" },
  { bg = "#3f51b5", fg = "#ffffff" },
  { bg = "#0b8043", fg = "#ffffff" },
  { bg = "#d50000", fg = "#ffffff" },
  { bg = "#795548", fg = "#ffffff" },
}

M.calendar_map = {}

local function hex_to_rgb(hex)
  hex = hex:gsub("#", "")
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local function darken(hex, factor)
  local r, g, b = hex_to_rgb(hex)
  r = math.floor(r * factor)
  g = math.floor(g * factor)
  b = math.floor(b * factor)
  return string.format("#%02x%02x%02x", r, g, b)
end

-- Perceived luminance (0–1). Used to pick a contrasting overlay colour.
local function luminance(hex)
  local r, g, b = hex_to_rgb(hex)
  local function lin(c)
    c = c / 255
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

-- Brighten a hex colour toward white by `factor` (0 = no change, 1 = white).
local function lighten(hex, factor)
  local r, g, b = hex_to_rgb(hex)
  r = math.min(255, math.floor(r + (255 - r) * factor))
  g = math.min(255, math.floor(g + (255 - g) * factor))
  b = math.min(255, math.floor(b + (255 - b) * factor))
  return string.format("#%02x%02x%02x", r, g, b)
end

-- Return a fg colour that is clearly visible on top of `bg_hex` while keeping
-- the same hue family: lighten on dark backgrounds, darken on light ones.
local function overlap_fg(bg_hex)
  if luminance(bg_hex) < 0.35 then
    return lighten(bg_hex, 0.75)
  else
    return darken(bg_hex, 0.35)
  end
end

function M.setup_highlights(calendars)
  M.calendar_map = {}
  local idx = 0

  for _, cal in ipairs(calendars) do
    idx = idx + 1
    local color
    if config.options.calendar_colors[cal.id] then
      color = { bg = config.options.calendar_colors[cal.id], fg = "#ffffff" }
    elseif cal.backgroundColor then
      color = { bg = cal.backgroundColor, fg = cal.foregroundColor or "#ffffff" }
    else
      color = palette[((idx - 1) % #palette) + 1]
    end

    local hl_name = "GcalCal" .. idx
    local hl_name_border = "GcalCalBorder" .. idx
    local hl_name_overlap = "GcalCalOverlap" .. idx
    vim.api.nvim_set_hl(0, hl_name, { bg = color.bg, fg = color.fg, bold = true })
    vim.api.nvim_set_hl(0, hl_name_border, { fg = color.bg })
    vim.api.nvim_set_hl(0, hl_name_overlap, {
      bg = color.bg,
      fg = overlap_fg(color.bg),
      bold = true,
      nocombine = true,
    })

    M.calendar_map[cal.id] = {
      index = idx,
      hl = hl_name,
      hl_border = hl_name_border,
      hl_overlap = hl_name_overlap,
      color = color,
      summary = cal.summary or cal.id,
    }
  end

  vim.api.nvim_set_hl(0, "GcalHeader", { bold = true, underline = true })
  vim.api.nvim_set_hl(0, "GcalTimeCol", { fg = "#bfc7d5", bold = true })
  vim.api.nvim_set_hl(0, "GcalGridLine", { fg = "#444444" })
  vim.api.nvim_set_hl(0, "GcalToday", { bg = "#274c77", fg = "#ffffff", bold = true, nocombine = true })
  vim.api.nvim_set_hl(0, "GcalTodayHeader", { bg = "#ffd166", fg = "#1f1f1f", bold = true, nocombine = true })
  vim.api.nvim_set_hl(0, "GcalNowLine", { bg = "#d62828", fg = "#ffffff", bold = true, nocombine = true })
  vim.api.nvim_set_hl(0, "GcalTitle", { fg = "#61afef", bold = true })
  vim.api.nvim_set_hl(0, "GcalAllDay", { bg = "#3b4261", fg = "#e2e8f0", italic = true })
  vim.api.nvim_set_hl(0, "GcalCursorEvent", { bg = "#ffffff", fg = "#1a1a1a", bold = true, nocombine = true })
end

function M.get_calendar_hl(calendar_id)
  local entry = M.calendar_map[calendar_id]
  if entry then
    return entry.hl
  end
  return "GcalCal1"
end

function M.get_calendar_overlap_hl(calendar_id)
  local entry = M.calendar_map[calendar_id]
  if entry then
    return entry.hl_overlap
  end
  return "GcalCalOverlap1"
end

function M.get_calendar_border_hl(calendar_id)
  local entry = M.calendar_map[calendar_id]
  if entry then
    return entry.hl_border
  end
  return "GcalCalBorder1"
end

return M
