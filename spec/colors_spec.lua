-- spec/colors_spec.lua
-- Tests for lua/gcal/colors.lua
-- Run with: make test   or   busted spec/colors_spec.lua

require("spec.support.init")

-- ── helpers ──────────────────────────────────────────────────────────────────

local function fresh()
  package.loaded["gcal.colors"] = nil
  package.loaded["gcal.config"] = nil
  -- Reset config to defaults (no user calendar_colors overrides)
  local cfg = require("gcal.config")
  cfg.setup({})
  return require("gcal.colors")
end

local function make_cal(id, summary, bg, fg)
  return { id = id, summary = summary, backgroundColor = bg, foregroundColor = fg }
end

-- ─────────────────────────────────────────────────────────────────────────────
describe("colors.setup_highlights", function()
  it("populates calendar_map for each calendar", function()
    local colors = fresh()
    local cals = { make_cal("cal1", "Work", "#7986cb", "#ffffff") }
    colors.setup_highlights(cals)
    assert.is_table(colors.calendar_map["cal1"])
  end)

  it("assigns sequential indices", function()
    local colors = fresh()
    local cals = {
      make_cal("a", "A", "#7986cb", "#ffffff"),
      make_cal("b", "B", "#33b679", "#ffffff"),
      make_cal("c", "C", "#8e24aa", "#ffffff"),
    }
    colors.setup_highlights(cals)
    assert.equal(1, colors.calendar_map["a"].index)
    assert.equal(2, colors.calendar_map["b"].index)
    assert.equal(3, colors.calendar_map["c"].index)
  end)

  it("sets hl names matching GcalCal<N> pattern", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("x", "X", "#039be5", "#ffffff") })
    assert.equal("GcalCal1",       colors.calendar_map["x"].hl)
    assert.equal("GcalCalBorder1", colors.calendar_map["x"].hl_border)
    assert.equal("GcalCalOverlap1",colors.calendar_map["x"].hl_overlap)
  end)

  it("uses backgroundColor from calendar when no config override", function()
    local colors = fresh()
    local bg = "#e67c73"
    colors.setup_highlights({ make_cal("m", "My Cal", bg, "#ffffff") })
    assert.equal(bg, colors.calendar_map["m"].color.bg)
  end)

  it("falls back to the built-in palette when no backgroundColor", function()
    local colors = fresh()
    -- Calendar without a backgroundColor
    colors.setup_highlights({ { id = "bare", summary = "Bare" } })
    local entry = colors.calendar_map["bare"]
    assert.is_table(entry)
    -- palette entry has a bg hex starting with #
    assert.matches("^#%x%x%x%x%x%x$", entry.color.bg)
  end)

  it("wraps the palette after 12 calendars", function()
    local colors = fresh()
    local cals = {}
    for i = 1, 13 do
      table.insert(cals, { id = "cal" .. i, summary = "Cal " .. i })
    end
    colors.setup_highlights(cals)
    -- Calendar 13 wraps back to palette index 1 (same bg as calendar 1)
    assert.equal(
      colors.calendar_map["cal1"].color.bg,
      colors.calendar_map["cal13"].color.bg
    )
  end)

  it("respects config.calendar_colors override", function()
    package.loaded["gcal.colors"] = nil
    package.loaded["gcal.config"] = nil
    local cfg = require("gcal.config")
    cfg.setup({ calendar_colors = { override_cal = "#123456" } })
    local colors = require("gcal.colors")

    colors.setup_highlights({ make_cal("override_cal", "Override", "#aabbcc", "#ffffff") })
    assert.equal("#123456", colors.calendar_map["override_cal"].color.bg)
  end)

  it("clears the calendar_map on each call", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("cal1", "A", "#7986cb", "#ffffff") })
    -- Second call with a different set — old entry should be gone
    colors.setup_highlights({ make_cal("cal2", "B", "#33b679", "#ffffff") })
    assert.is_nil(colors.calendar_map["cal1"])
    assert.is_table(colors.calendar_map["cal2"])
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("colors.get_calendar_hl", function()
  it("returns the correct hl group for a known calendar", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("c1", "C1", "#7986cb", "#ffffff") })
    assert.equal("GcalCal1", colors.get_calendar_hl("c1"))
  end)

  it("returns GcalCal1 as fallback for unknown calendar", function()
    local colors = fresh()
    colors.setup_highlights({})
    assert.equal("GcalCal1", colors.get_calendar_hl("does_not_exist"))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("colors.get_calendar_overlap_hl", function()
  it("returns the correct overlap hl group for a known calendar", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("c1", "C1", "#7986cb", "#ffffff") })
    assert.equal("GcalCalOverlap1", colors.get_calendar_overlap_hl("c1"))
  end)

  it("returns GcalCalOverlap1 as fallback for unknown calendar", function()
    local colors = fresh()
    colors.setup_highlights({})
    assert.equal("GcalCalOverlap1", colors.get_calendar_overlap_hl("unknown"))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("colors.get_calendar_border_hl", function()
  it("returns the correct border hl group for a known calendar", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("c1", "C1", "#7986cb", "#ffffff") })
    assert.equal("GcalCalBorder1", colors.get_calendar_border_hl("c1"))
  end)

  it("returns GcalCalBorder1 as fallback for unknown calendar", function()
    local colors = fresh()
    colors.setup_highlights({})
    assert.equal("GcalCalBorder1", colors.get_calendar_border_hl("unknown"))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("colors highlight groups registered with vim.api", function()
  it("registers GcalHeader after setup_highlights", function()
    local colors = fresh()
    colors.setup_highlights({})
    local hl = vim.api.nvim_get_hl(0, { name = "GcalHeader" })
    assert.is_table(hl)
  end)

  it("registers GcalToday after setup_highlights", function()
    local colors = fresh()
    colors.setup_highlights({})
    local hl = vim.api.nvim_get_hl(0, { name = "GcalToday" })
    assert.is_table(hl)
  end)

  it("registers per-calendar GcalCal1 after setup_highlights with one calendar", function()
    local colors = fresh()
    colors.setup_highlights({ make_cal("x", "X", "#f6bf26", "#1a1a1a") })
    local hl = vim.api.nvim_get_hl(0, { name = "GcalCal1" })
    assert.is_table(hl)
  end)
end)
