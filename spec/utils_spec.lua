-- spec/utils_spec.lua
-- Tests for lua/gcal/utils.lua
-- Run with: make test   or   busted spec/utils_spec.lua

require("spec.support.init")
local utils = require("gcal.utils")

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.url_encode", function()
  it("encodes spaces as +", function()
    assert.equal("hello+world", utils.url_encode("hello world"))
  end)

  it("percent-encodes special characters", function()
    local encoded = utils.url_encode("a=b&c=d")
    assert.equal("a%3Db%26c%3Dd", encoded)
  end)

  it("leaves unreserved characters untouched", function()
    assert.equal("abc123", utils.url_encode("abc123"))
  end)

  it("encodes newlines as %0D%0A", function()
    local encoded = utils.url_encode("\n")
    assert.equal("%0D%0A", encoded)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.url_decode", function()
  it("decodes + as space", function()
    assert.equal("hello world", utils.url_decode("hello+world"))
  end)

  it("decodes percent-encoded sequences", function()
    assert.equal("a=b&c=d", utils.url_decode("a%3Db%26c%3Dd"))
  end)

  it("is inverse of url_encode for simple strings", function()
    local original = "foo bar/baz"
    assert.equal(original, utils.url_decode(utils.url_encode(original)))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.parse_query_string", function()
  it("parses key=value pairs", function()
    local params = utils.parse_query_string("code=abc&state=xyz")
    assert.equal("abc", params["code"])
    assert.equal("xyz", params["state"])
  end)

  it("decodes percent-encoded values", function()
    local params = utils.parse_query_string("redirect_uri=http%3A%2F%2Flocalhost")
    assert.equal("http://localhost", params["redirect_uri"])
  end)

  it("returns empty table for empty string", function()
    local params = utils.parse_query_string("")
    assert.same({}, params)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.iso8601_to_timestamp", function()
  it("parses a date-only string and marks it as all-day", function()
    local ts, all_day = utils.iso8601_to_timestamp("2025-06-15")
    assert.is_true(all_day)
    -- Verify year/month/day round-trips
    local d = os.date("*t", ts)
    assert.equal(2025, d.year)
    assert.equal(6,    d.month)
    assert.equal(15,   d.day)
  end)

  it("parses a UTC datetime string and returns false for all_day", function()
    local ts, all_day = utils.iso8601_to_timestamp("2025-06-15T14:30:00Z")
    assert.is_false(all_day)
    assert.is_number(ts)
    assert.is_true(ts > 0)
  end)

  it("returns nil for nil input", function()
    local ts = utils.iso8601_to_timestamp(nil)
    assert.is_nil(ts)
  end)

  it("returns nil for an invalid string", function()
    local ts = utils.iso8601_to_timestamp("not-a-date")
    assert.is_nil(ts)
  end)

  it("handles positive timezone offset", function()
    -- +02:00 means 2 hours ahead of UTC, so UTC time is 2h earlier
    local ts_utc, _  = utils.iso8601_to_timestamp("2025-01-01T12:00:00Z")
    local ts_plus, _ = utils.iso8601_to_timestamp("2025-01-01T14:00:00+02:00")
    -- Both should represent the same instant (within rounding of local_offset math)
    assert.equal(ts_utc, ts_plus)
  end)

  it("handles negative timezone offset", function()
    local ts_utc, _   = utils.iso8601_to_timestamp("2025-01-01T12:00:00Z")
    local ts_minus, _ = utils.iso8601_to_timestamp("2025-01-01T10:00:00-02:00")
    assert.equal(ts_utc, ts_minus)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.timestamp_to_iso8601", function()
  it("formats timestamp as ISO8601 UTC", function()
    -- 2025-01-01T00:00:00Z  →  1735689600
    local ts = os.time({ year=2025, month=1, day=1, hour=0, min=0, sec=0 })
    -- We test structural correctness rather than an exact number
    local iso = utils.timestamp_to_iso8601(ts)
    assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", iso)
  end)

  it("round-trips through iso8601_to_timestamp (UTC)", function()
    local ts_original = os.time({ year=2024, month=6, day=20, hour=10, min=30, sec=0 })
    local iso = utils.timestamp_to_iso8601(ts_original)
    local ts_back, _ = utils.iso8601_to_timestamp(iso)
    assert.equal(ts_original, ts_back)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.format_time", function()
  -- Use a fixed timestamp: midnight UTC on 2024-01-01
  -- os.time in local tz — pick noon to avoid date rollover
  local noon = os.time({ year=2024, month=1, day=1, hour=12, min=30, sec=0 })

  it("formats in 24h by default", function()
    local result = utils.format_time(noon, "24h")
    assert.matches("^%d%d:%d%d$", result)
    -- Should contain "12:30" in local time (noon)
    assert.equal("12:30", result)
  end)

  it("formats in 12h with AM/PM", function()
    local result = utils.format_time(noon, "12h")
    -- Should contain "12:30" and either AM or PM
    assert.matches("12:30", result)
    assert.matches("[AP]M", result)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.get_week_bounds", function()
  -- 2024-01-15 is a Monday (wday=2)
  local monday = os.time({ year=2024, month=1, day=15, hour=12, min=0, sec=0 })

  it("returns sunday..saturday when week_start='sunday'", function()
    local ws, we = utils.get_week_bounds(monday, "sunday")
    local d_start = os.date("*t", ws)
    local d_end   = os.date("*t", we)
    -- Start should be the previous Sunday (Jan 14)
    assert.equal(1, d_start.wday)   -- Sunday
    assert.equal(7, d_end.wday)     -- Saturday
  end)

  it("returns monday..sunday when week_start='monday'", function()
    local ws, we = utils.get_week_bounds(monday, "monday")
    local d_start = os.date("*t", ws)
    local d_end   = os.date("*t", we)
    assert.equal(2, d_start.wday)   -- Monday
    assert.equal(1, d_end.wday)     -- Sunday
  end)

  it("week spans exactly 7 days minus 1 second", function()
    local ws, we = utils.get_week_bounds(monday, "monday")
    assert.equal(7 * 24 * 3600 - 1, we - ws)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.get_day_dates", function()
  local monday = os.time({ year=2024, month=1, day=15, hour=0, min=0, sec=0 })

  it("returns exactly 7 entries", function()
    local days = utils.get_day_dates(monday)
    assert.equal(7, #days)
  end)

  it("consecutive days differ by exactly 86400 seconds", function()
    local days = utils.get_day_dates(monday)
    for i = 2, 7 do
      assert.equal(86400, days[i] - days[i - 1])
    end
  end)

  it("first entry equals the supplied timestamp", function()
    local days = utils.get_day_dates(monday)
    assert.equal(monday, days[1])
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.ascii_safe", function()
  it("returns empty string for nil input", function()
    assert.equal("", utils.ascii_safe(nil))
  end)

  it("leaves plain ASCII untouched", function()
    assert.equal("hello world", utils.ascii_safe("hello world"))
  end)

  it("transliterates common accented characters", function()
    assert.equal("cafe", utils.ascii_safe("café"))
    assert.equal("resume", utils.ascii_safe("résumé"))
    assert.equal("Uber", utils.ascii_safe("Über"))
  end)

  it("expands digraph ligatures", function()
    assert.equal("AE", utils.ascii_safe("Æ"))
    assert.equal("ae", utils.ascii_safe("æ"))
    assert.equal("ss", utils.ascii_safe("ß"))
    assert.equal("OE", utils.ascii_safe("Œ"))
  end)

  it("drops non-transliterable non-ASCII characters", function()
    -- Greek alpha has no mapping and should be dropped
    local result = utils.ascii_safe("helloαworld")
    assert.equal("helloworld", result)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.truncate", function()
  it("returns empty string for nil input", function()
    assert.equal("", utils.truncate(nil, 10))
  end)

  it("returns the string unchanged when shorter than max_len", function()
    assert.equal("hi", utils.truncate("hi", 10))
  end)

  it("returns the string unchanged when equal to max_len", function()
    assert.equal("hello", utils.truncate("hello", 5))
  end)

  it("appends '..' when the string is longer than max_len", function()
    local result = utils.truncate("hello world", 7)
    assert.equal(7, #result)
    assert.matches("%.%.$", result)
  end)

  it("applies ascii_safe before truncating", function()
    -- 'é' becomes 'e', so "héllo" → "hello"
    local result = utils.truncate("héllo", 10)
    assert.equal("hello", result)
  end)

  it("handles max_len <= 2", function()
    local result = utils.truncate("hello", 2)
    assert.equal("he", result)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.get_meeting_url", function()
  it("returns video entry point from conferenceData", function()
    local event = {
      conferenceData = {
        entryPoints = {
          { entryPointType = "phone", uri = "tel:+1234567890" },
          { entryPointType = "video", uri = "https://meet.example.com/xyz" },
        },
      },
    }
    assert.equal("https://meet.example.com/xyz", utils.get_meeting_url(event))
  end)

  it("falls back to hangoutLink when no conferenceData", function()
    local event = { hangoutLink = "https://meet.google.com/abc-def-ghi" }
    assert.equal("https://meet.google.com/abc-def-ghi", utils.get_meeting_url(event))
  end)

  it("falls back to htmlLink as last resort", function()
    local event = { htmlLink = "https://calendar.google.com/event?eid=xxx" }
    assert.equal("https://calendar.google.com/event?eid=xxx", utils.get_meeting_url(event))
  end)

  it("returns nil when no URL is available", function()
    assert.is_nil(utils.get_meeting_url({}))
  end)

  it("prefers conferenceData over hangoutLink", function()
    local event = {
      hangoutLink = "https://meet.google.com/fallback",
      conferenceData = {
        entryPoints = {
          { entryPointType = "video", uri = "https://meet.google.com/primary" },
        },
      },
    }
    assert.equal("https://meet.google.com/primary", utils.get_meeting_url(event))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
describe("utils.is_confirmed_for_me", function()
  it("returns true when self attendee accepted", function()
    local event = {
      attendees = {
        { email = "me@example.com", self = true, responseStatus = "accepted" },
      },
    }
    assert.is_true(utils.is_confirmed_for_me(event))
  end)

  it("returns false when self attendee declined", function()
    local event = {
      attendees = {
        { email = "me@example.com", self = true, responseStatus = "declined" },
      },
      organizer = { self = true },
    }
    assert.is_false(utils.is_confirmed_for_me(event))
  end)

  it("uses organizer.self as fallback when self attendee is missing", function()
    local event = {
      organizer = { self = true },
      attendees = {
        { email = "other@example.com", responseStatus = "accepted" },
      },
    }
    assert.is_true(utils.is_confirmed_for_me(event))
  end)

  it("returns false when no self attendee and organizer is not self", function()
    local event = {
      organizer = { self = false },
      attendees = {
        { email = "other@example.com", responseStatus = "accepted" },
      },
    }
    assert.is_false(utils.is_confirmed_for_me(event))
  end)
end)
