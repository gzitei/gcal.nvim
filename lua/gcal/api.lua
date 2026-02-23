local curl = require("plenary.curl")
local config = require("gcal.config")
local auth = require("gcal.auth")
local utils = require("gcal.utils")
local cache = require("gcal.cache")

local M = {}

local BASE_URL = "https://www.googleapis.com/calendar/v3"

---@param endpoint string
---@param params? table<string, string|number>
---@param callback fun(data: table?)|nil
local function api_get(endpoint, params, callback)
  auth.get_access_token(function(token)
    if not token then
      return
    end
    local query = {}
    if params then
      for k, v in pairs(params) do
        table.insert(query, k .. "=" .. utils.url_encode(tostring(v)))
      end
    end
    local url = BASE_URL .. endpoint
    if #query > 0 then
      url = url .. "?" .. table.concat(query, "&")
    end
    curl.get(url, {
      headers = {
        authorization = "Bearer " .. token,
      },
      callback = function(response)
        vim.schedule(function()
          if response.status == 401 then
            auth.refresh_token(function(tokens)
              if tokens then
                api_get(endpoint, params, callback)
              end
            end)
            return
          end
          if response.status ~= 200 then
            vim.notify(
              "Calendar API error (" .. response.status .. ")",
              vim.log.levels.ERROR,
              { title = "gcal.nvim" }
            )
            if callback then
              callback(nil)
            end
            return
          end
          local ok, data = pcall(vim.json.decode, response.body)
          if ok then
            callback(data)
          else
            vim.notify("Failed to parse API response", vim.log.levels.ERROR, { title = "gcal.nvim" })
            callback(nil)
          end
        end)
      end,
    })
  end)
end

---@param callback fun(calendars: table[])|nil
function M.list_calendars(callback)
  api_get("/users/me/calendarList", { minAccessRole = "reader" }, function(data)
    if not data then
      callback({})
      return
    end
    callback(data.items or {})
  end)
end

---@param calendar_id string
---@param time_min number
---@param time_max number
---@param callback fun(events: table[])|nil
function M.get_events(calendar_id, time_min, time_max, callback)
  local params = {
    timeMin = utils.timestamp_to_iso8601(time_min),
    timeMax = utils.timestamp_to_iso8601(time_max),
    singleEvents = "true",
    orderBy = "startTime",
    maxResults = "250",
  }
  local encoded_id = utils.url_encode(calendar_id)
  api_get("/calendars/" .. encoded_id .. "/events", params, function(data)
    if not data then
      callback({})
      return
    end
    local events = data.items or {}
    for _, event in ipairs(events) do
      event._calendar_id = calendar_id
    end
    local filtered = {}
    for _, event in ipairs(events) do
      if event.eventType ~= "workingLocation" then
        table.insert(filtered, event)
      end
    end
    callback(filtered)
  end)
end

-- opts (optional table):
--   cache_key  : "current_week" | "next_week" | nil (nil = always live, no cache)
--   cache_ttl  : TTL in seconds for the cache entry
--   force      : if true, invalidate the cache entry before fetching
--   once       : if true, callback is called at most once (skip background refresh)
--
-- callback is called with (events, calendars).
-- When the cache is warm it is called immediately with cached data, then a
-- second time once the background network refresh completes (unless once=true).
---@param time_min number
---@param time_max number
---@param callback fun(events: table[], calendars: table[])|nil
---@param opts? {cache_key?: string, cache_ttl?: number, force?: boolean, once?: boolean}
function M.get_all_events(time_min, time_max, callback, opts)
  opts = opts or {}
  local key = opts.cache_key
  local ttl = opts.cache_ttl
  local force = opts.force
  local once = opts.once

  -- No cache: straight live fetch
  if not key then
    M._fetch_all_events(time_min, time_max, function(events, calendars)
      callback(events or {}, calendars or {})
    end)
    return
  end

  if force then
    cache.invalidate(key)
  end

  -- Serve cached data instantly if fresh
  local cached_events, cached_calendars = cache.get(key, ttl)
  if cached_events then
    callback(cached_events, cached_calendars)
    if not force and not once then
      -- Background refresh to keep cache warm
      M._fetch_all_events(time_min, time_max, function(events, calendars)
        if events then
          cache.set(key, events, calendars)
          callback(events, calendars)
        end
      end)
    end
  end

  -- Cache miss or forced: fetch now, persist, then callback
  if not cached_events or force then
    M._fetch_all_events(time_min, time_max, function(events, calendars)
      if events then
        cache.set(key, events, calendars)
        callback(events, calendars)
      else
        -- API failed — serve stale cache rather than nothing
        local stale_e, stale_c = cache.get(key)
        callback(stale_e or {}, stale_c or {})
      end
    end)
  end
end

--- Internal: unconditional network fetch of all events.
---@param time_min number
---@param time_max number
---@param callback fun(events: table[], calendars: table[])|nil
function M._fetch_all_events(time_min, time_max, callback)
  M.list_calendars(function(calendars)
    if not calendars or #calendars == 0 then
      callback({}, {})
      return
    end

    local filtered = calendars
    if config.options.calendars and #config.options.calendars > 0 then
      filtered = {}
      local wanted = {}
      for _, id in ipairs(config.options.calendars) do
        wanted[id] = true
      end
      for _, cal in ipairs(calendars) do
        if wanted[cal.id] then
          table.insert(filtered, cal)
        end
      end
    end

    if #filtered == 0 then
      callback({}, calendars)
      return
    end

    local all_events = {}
    local pending = #filtered
    for _, cal in ipairs(filtered) do
      M.get_events(cal.id, time_min, time_max, function(events)
        for _, ev in ipairs(events) do
          table.insert(all_events, ev)
        end
        pending = pending - 1
        if pending == 0 then
          table.sort(all_events, function(a, b)
            local a_start = (a.start and (a.start.dateTime or a.start.date)) or ""
            local b_start = (b.start and (b.start.dateTime or b.start.date)) or ""
            return a_start < b_start
          end)
          callback(all_events, calendars)
        end
      end)
    end
  end)
end

return M
