-- spec/cache_spec.lua
-- Tests for lua/gcal/cache.lua
-- Run with: make test   or   busted spec/cache_spec.lua

require("spec.support.init")

-- ── helpers ──────────────────────────────────────────────────────────────────

local function fresh_cache()
  -- Wipe module state so every describe block starts clean.
  package.loaded["gcal.cache"]  = nil
  package.loaded["gcal.config"] = nil
  return require("gcal.cache")
end

local EVENTS_A    = { { id = "e1", summary = "Alpha" } }
local EVENTS_B    = { { id = "e2", summary = "Beta" }  }
local CALENDARS_A = { { id = "cal1", summary = "Work" } }
local CALENDARS_B = { { id = "cal2", summary = "Personal" } }

-- ─────────────────────────────────────────────────────────────────────────────
describe("cache.set / cache.get", function()
  local cache

  before_each(function()
    cache = fresh_cache()
  end)

  it("returns nil for an unknown key", function()
    local events, calendars = cache.get("current_week", 300)
    assert.is_nil(events)
    assert.is_nil(calendars)
  end)

  it("stores and retrieves events and calendars", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    local events, calendars = cache.get("current_week", 300)
    assert.same(EVENTS_A,    events)
    assert.same(CALENDARS_A, calendars)
  end)

  it("stores and retrieves for next_week key", function()
    cache.set("next_week", EVENTS_B, CALENDARS_B)
    local events, calendars = cache.get("next_week", 300)
    assert.same(EVENTS_B,    events)
    assert.same(CALENDARS_B, calendars)
  end)

  it("silently ignores an invalid key on set", function()
    cache.set("bad_key", EVENTS_A, CALENDARS_A)
    local events, _ = cache.get("bad_key", 300)
    assert.is_nil(events)
  end)

  it("returns nil for an invalid key on get", function()
    local events, _ = cache.get("invalid_key", 300)
    assert.is_nil(events)
  end)

  it("returns nil when max_age_seconds=0 (immediately stale)", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    -- os.time advances at 1-second granularity; sleep 1s to guarantee staleness.
    -- To avoid a slow test we instead mock os.time.
    local real_time = os.time
    -- Simulate the entry having been saved 10 seconds ago
    _G.os = setmetatable({ time = function() return real_time() + 10 end }, { __index = os })
    local events, _ = cache.get("current_week", 5)
    _G.os = os  -- restore
    assert.is_nil(events)
  end)

  it("returns data when within max_age_seconds", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    local events, calendars = cache.get("current_week", 3600)
    assert.same(EVENTS_A,    events)
    assert.same(CALENDARS_A, calendars)
  end)

  it("returns data when max_age_seconds is nil (no TTL)", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    local events, calendars = cache.get("current_week", nil)
    assert.same(EVENTS_A,    events)
    assert.same(CALENDARS_A, calendars)
  end)

  it("overwrites a previous entry", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.set("current_week", EVENTS_B, CALENDARS_B)
    local events, calendars = cache.get("current_week", 300)
    assert.same(EVENTS_B,    events)
    assert.same(CALENDARS_B, calendars)
  end)

  it("keeps current_week and next_week independent", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.set("next_week",    EVENTS_B, CALENDARS_B)

    local ev_cw, cal_cw = cache.get("current_week", 300)
    local ev_nw, cal_nw = cache.get("next_week",    300)

    assert.same(EVENTS_A,    ev_cw)
    assert.same(CALENDARS_A, cal_cw)
    assert.same(EVENTS_B,    ev_nw)
    assert.same(CALENDARS_B, cal_nw)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("cache.invalidate", function()
  local cache

  before_each(function()
    cache = fresh_cache()
  end)

  it("causes subsequent get to return nil", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.invalidate("current_week")
    local events, _ = cache.get("current_week", 300)
    assert.is_nil(events)
  end)

  it("only invalidates the specified key", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.set("next_week",    EVENTS_B, CALENDARS_B)
    cache.invalidate("current_week")

    local ev_cw, _ = cache.get("current_week", 300)
    local ev_nw, _ = cache.get("next_week",    300)
    assert.is_nil(ev_cw)
    assert.same(EVENTS_B, ev_nw)
  end)

  it("silently ignores an invalid key", function()
    -- Should not raise
    assert.has_no.errors(function()
      cache.invalidate("nonexistent_key")
    end)
  end)

  it("is idempotent (double-invalidate is safe)", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.invalidate("current_week")
    assert.has_no.errors(function()
      cache.invalidate("current_week")
    end)
    local events, _ = cache.get("current_week", 300)
    assert.is_nil(events)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("cache disk persistence", function()
  local cache

  before_each(function()
    -- Clean up any leftover disk files from previous runs
    local dir = "/tmp/gcal_test_cache/gcal"
    os.execute('rm -rf "' .. dir .. '"')
    cache = fresh_cache()
  end)

  it("persists to disk and can be read back after memory is cleared", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)

    -- Evict only the memory layer by loading a fresh module
    -- (disk file should still exist)
    package.loaded["gcal.cache"] = nil
    local cache2 = require("gcal.cache")

    local events, calendars = cache2.get("current_week", 300)
    assert.same(EVENTS_A,    events)
    assert.same(CALENDARS_A, calendars)
  end)

  it("invalidate removes the disk file", function()
    cache.set("current_week", EVENTS_A, CALENDARS_A)
    cache.invalidate("current_week")

    -- Fresh module with empty memory — disk file should be gone
    package.loaded["gcal.cache"] = nil
    local cache2 = require("gcal.cache")
    local events, _ = cache2.get("current_week", 300)
    assert.is_nil(events)
  end)
end)
