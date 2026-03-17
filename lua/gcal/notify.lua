local config = require("gcal.config")
local api = require("gcal.api")
local utils = require("gcal.utils")

local M = {}

local poll_timer = nil
local notified = {}
local countdown_timers = {}

local function open_url(url)
  if not url or url == "" then
    return
  end
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", url }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end

-- Attach a <CR> keymap to a notification window once it opens.
-- `opts` is the options table passed to nvim-notify; this function injects
-- an `on_open` callback into it so we get the window handle reliably.
local function inject_url_keymap(opts, url)
  if not url or url == "" then
    return opts
  end
  local prev_on_open = opts.on_open
  opts.on_open = function(win)
    if prev_on_open then prev_on_open(win) end
    if not vim.api.nvim_win_is_valid(win) then return end
    local buf = vim.api.nvim_win_get_buf(win)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.keymap.set("n", "<CR>", function()
      open_url(url)
    end, { buffer = buf, silent = true, nowait = true, desc = "Open event URL" })
  end
  return opts
end

local function build_message(event, prefix)
  local lines = { prefix .. ": " .. (event.summary or "(No title)") }
  local url = utils.get_meeting_url(event)
  if url then
    table.insert(lines, url)
  end
  return table.concat(lines, "\n"), url
end

-- Returns the nvim-notify module if available, otherwise nil.
local function get_nvim_notify()
  local ok, n = pcall(require, "notify")
  if ok and type(n) == "table" and type(n.notify) == "function" then
    return n
  end
  return nil
end

local function start_countdown(event, seconds_until)
  local event_key = event.id or event.summary or tostring(event)
  if countdown_timers[event_key] then
    return
  end

  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  local countdown_secs = config.options.countdown.seconds
  local remaining = math.min(countdown_secs, math.floor(seconds_until))
  local notification_id = nil  -- holds the nvim-notify record for replace

  countdown_timers[event_key] = timer

  local initial_delay = math.max(0, math.floor((seconds_until - remaining) * 1000))

  local nvim_notify = get_nvim_notify()

  timer:start(initial_delay, 1000, vim.schedule_wrap(function()
    if remaining > 0 then
      local msg, url = build_message(event, string.format("Starting in %ds", remaining))
      if nvim_notify then
        -- Replace the existing notification in-place so no new window is spawned.
        -- timeout = false keeps it visible until the next tick replaces it.
        notification_id = nvim_notify.notify(msg, vim.log.levels.INFO,
          inject_url_keymap({
            title = "Google Calendar",
            replace = notification_id,
            timeout = false,
          }, url))
      else
        vim.notify(msg, vim.log.levels.INFO, { title = "Google Calendar", timeout = 1500 })
      end
    else
      local msg, url = build_message(event, "Meeting starting NOW")
      if nvim_notify then
        local notif = nvim_notify.notify(msg, vim.log.levels.WARN,
          inject_url_keymap({
            title = "Google Calendar",
            replace = notification_id,
            timeout = config.options.countdown.final_timeout,
          }, url))
        notification_id = notif
      else
        vim.notify(msg, vim.log.levels.WARN, {
          title = "Google Calendar",
          timeout = config.options.countdown.final_timeout,
        })
      end
      timer:stop()
      timer:close()
      countdown_timers[event_key] = nil
    end
    remaining = remaining - 1
  end))
end

local function check_events(events)
  local now = os.time()

  for _, event in ipairs(events) do
    if not event.start then
      goto continue
    end

    local start_str = event.start.dateTime
    if not start_str then
      goto continue
    end

    local start_ts = utils.iso8601_to_timestamp(start_str)
    if not start_ts then
      goto continue
    end

    local diff_seconds = start_ts - now
    if diff_seconds < 0 then
      goto continue
    end

    local event_key = event.id or event.summary or tostring(event)
    local is_confirmed = utils.is_confirmed_for_me(event)

    if is_confirmed then
      for _, minutes in ipairs(config.options.alert_minutes) do
        local alert_key = event_key .. ":" .. minutes
        local window_start = minutes * 60
        local window_end = window_start - config.options.poll_interval_seconds
        if window_end < 0 then
          window_end = 0
        end

        if diff_seconds <= window_start and diff_seconds > window_end and not notified[alert_key] then
          notified[alert_key] = true
          local msg, url = build_message(event, string.format("In %d min", minutes))
          local nvim_notify = get_nvim_notify()
          if nvim_notify then
            nvim_notify.notify(msg, vim.log.levels.INFO,
              inject_url_keymap({ title = "Google Calendar", timeout = 8000 }, url))
          else
            vim.notify(msg, vim.log.levels.INFO, { title = "Google Calendar", timeout = 8000 })
          end
        end
      end

      if config.options.countdown.enabled then
        local countdown_secs = config.options.countdown.seconds
        if diff_seconds <= countdown_secs and diff_seconds > 0 then
          start_countdown(event, diff_seconds)
        end
      end
    else
      local now_key = event_key .. ":starting_now"
      local now_window = config.options.poll_interval_seconds
      if diff_seconds <= now_window and diff_seconds >= 0 and not notified[now_key] then
        notified[now_key] = true
        local msg, url = build_message(event, "Meeting starting NOW")
        local nvim_notify = get_nvim_notify()
        if nvim_notify then
          nvim_notify.notify(msg, vim.log.levels.INFO,
            inject_url_keymap({ title = "Google Calendar", timeout = config.options.countdown.final_timeout }, url))
        else
          vim.notify(msg, vim.log.levels.INFO, {
            title = "Google Calendar",
            timeout = config.options.countdown.final_timeout,
          })
        end
      end
    end

    ::continue::
  end
end

local function poll()
  local now = os.time()
  local week_start = utils.get_week_bounds(now, config.options.week_start)
  local week_end = week_start + 7 * 86400
  local ttl = config.options.poll_interval_seconds or 60

  api.get_all_events(week_start, week_end, function(events)
    if events then
      check_events(events)
    end
  end, { cache_key = "current_week", cache_ttl = ttl })
end

function M.start()
  if poll_timer then
    return
  end

  local uv = vim.uv or vim.loop
  poll_timer = uv.new_timer()
  local interval = config.options.poll_interval_seconds * 1000

  poll_timer:start(0, interval, vim.schedule_wrap(function()
    poll()
  end))
end

function M.stop()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end

  for key, timer in pairs(countdown_timers) do
    timer:stop()
    timer:close()
    countdown_timers[key] = nil
  end
end

function M.toggle(enable)
  if enable == nil then
    enable = not (poll_timer ~= nil)
  end
  if enable then
    config.options.alerts_enabled = true
    M.start()
    vim.notify("Alerts enabled", vim.log.levels.INFO, { title = "gcal.nvim" })
  else
    config.options.alerts_enabled = false
    M.stop()
    vim.notify("Alerts disabled", vim.log.levels.INFO, { title = "gcal.nvim" })
  end
end

function M.clear_cache()
  notified = {}
end

return M
