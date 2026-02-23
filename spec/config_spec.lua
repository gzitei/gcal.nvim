-- spec/config_spec.lua
-- Tests for lua/gcal/config.lua
-- Run with: make test   or   busted spec/config_spec.lua

require("spec.support.init")

describe("config", function()
  -- Re-require fresh each time so tests don't bleed into each other.
  local function fresh()
    package.loaded["gcal.config"] = nil
    return require("gcal.config")
  end

  -- ── defaults ───────────────────────────────────────────────────────────────
  describe("defaults", function()
    it("has empty client_id and client_secret", function()
      local cfg = fresh()
      assert.equal("", cfg.defaults.client_id)
      assert.equal("", cfg.defaults.client_secret)
    end)

    it("has an empty calendars list", function()
      local cfg = fresh()
      assert.same({}, cfg.defaults.calendars)
    end)

    it("provides default alert_minutes", function()
      local cfg = fresh()
      assert.same({ 10, 3 }, cfg.defaults.alert_minutes)
    end)

    it("enables alerts by default", function()
      local cfg = fresh()
      assert.is_true(cfg.defaults.alerts_enabled)
    end)

    it("has a 60-second poll interval", function()
      local cfg = fresh()
      assert.equal(60, cfg.defaults.poll_interval_seconds)
    end)

    it("defaults to sunday week start", function()
      local cfg = fresh()
      assert.equal("sunday", cfg.defaults.week_start)
    end)

    it("defaults to 24h time format", function()
      local cfg = fresh()
      assert.equal("24h", cfg.defaults.time_format)
    end)

    it("has a float view enabled by default", function()
      local cfg = fresh()
      assert.is_true(cfg.defaults.view.float)
    end)

    it("has sensible view dimensions", function()
      local cfg = fresh()
      assert.equal(0.85, cfg.defaults.view.width)
      assert.equal(0.85, cfg.defaults.view.height)
    end)

    it("has default day_start_hour and day_end_hour", function()
      local cfg = fresh()
      assert.equal(7,  cfg.defaults.view.day_start_hour)
      assert.equal(19, cfg.defaults.view.day_end_hour)
    end)

    it("has default auth port 8234", function()
      local cfg = fresh()
      assert.equal(8234, cfg.defaults.auth.port)
    end)

    it("has a token_path under stdpath('data')", function()
      local cfg = fresh()
      assert.matches("gcal/tokens%.json$", cfg.defaults.auth.token_path)
    end)

    it("has countdown enabled by default", function()
      local cfg = fresh()
      assert.is_true(cfg.defaults.countdown.enabled)
    end)

    it("has countdown.seconds = 30", function()
      local cfg = fresh()
      assert.equal(30, cfg.defaults.countdown.seconds)
    end)

    it("has countdown.final_timeout = 10000", function()
      local cfg = fresh()
      assert.equal(10000, cfg.defaults.countdown.final_timeout)
    end)
  end)

  -- ── setup() ───────────────────────────────────────────────────────────────
  describe("setup()", function()
    it("populates options with defaults when called with no args", function()
      local cfg = fresh()
      cfg.setup()
      assert.equal("", cfg.options.client_id)
      assert.equal(60, cfg.options.poll_interval_seconds)
    end)

    it("merges user options over defaults", function()
      local cfg = fresh()
      cfg.setup({ client_id = "my_id", client_secret = "my_secret" })
      assert.equal("my_id",     cfg.options.client_id)
      assert.equal("my_secret", cfg.options.client_secret)
      -- Unset keys keep their defaults
      assert.equal(60, cfg.options.poll_interval_seconds)
    end)

    it("deep-merges nested tables", function()
      local cfg = fresh()
      cfg.setup({ view = { width = 0.5 } })
      assert.equal(0.5,  cfg.options.view.width)
      -- height should still be the default
      assert.equal(0.85, cfg.options.view.height)
    end)

    it("deep-merges auth sub-table", function()
      local cfg = fresh()
      cfg.setup({ auth = { port = 9000 } })
      assert.equal(9000, cfg.options.auth.port)
      -- token_path should still be the default
      assert.matches("gcal/tokens%.json$", cfg.options.auth.token_path)
    end)

    it("does not mutate defaults", function()
      local cfg = fresh()
      cfg.setup({ client_id = "changed" })
      -- defaults must be unaffected
      assert.equal("", cfg.defaults.client_id)
    end)

    it("allows week_start to be overridden to 'monday'", function()
      local cfg = fresh()
      cfg.setup({ week_start = "monday" })
      assert.equal("monday", cfg.options.week_start)
    end)

    it("allows alerts_enabled to be disabled", function()
      local cfg = fresh()
      cfg.setup({ alerts_enabled = false })
      assert.is_false(cfg.options.alerts_enabled)
    end)

    it("merges alert_minutes (tbl_deep_extend merges by index)", function()
      -- vim.tbl_deep_extend treats array-like tables as maps keyed by index.
      -- Providing {5} overrides index 1 but keeps existing index 2 from defaults.
      local cfg = fresh()
      cfg.setup({ alert_minutes = { 5 } })
      assert.equal(5, cfg.options.alert_minutes[1])
    end)
  end)
end)
