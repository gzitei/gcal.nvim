local M = {}

-- Type annotations (EmmyLua) for configuration structure.
---@class GcalView
---@field float boolean
---@field width number
---@field height number
---@field day_start_hour number
---@field day_end_hour number

---@class GcalAuth
---@field port number
---@field token_path string

---@class GcalCountdown
---@field enabled boolean
---@field seconds number
---@field final_timeout number

---@class GcalKeymaps
---@field close string
---@field prev_week string|table
---@field next_week string|table
---@field today string|table
---@field refresh string
---@field open_url string
---@field hover string
---@field next_event string
---@field prev_event string
---@field open_gcal string

---@class GcalDefaults
---@field client_id string
---@field client_secret string
---@field calendars table
---@field alert_minutes table
---@field alerts_enabled boolean
---@field poll_interval_seconds number
---@field week_start string
---@field time_format string
---@field view GcalView
---@field auth GcalAuth
---@field calendar_colors table
---@field countdown GcalCountdown
---@field keymaps GcalKeymaps

---@type table<string, any>
M.defaults = {
    client_id = '',
    client_secret = '',
    calendars = {},
    alert_minutes = { 10, 3 },
    alerts_enabled = true,
    poll_interval_seconds = 60,
    week_start = 'sunday',
    time_format = '24h',
    view = {
        float = true,
        width = 0.85,
        height = 0.85,
        day_start_hour = 7,
        day_end_hour = 19,
    },
    auth = {
        port = 8234,
        token_path = vim.fn.stdpath('data') .. '/gcal/tokens.json',
    },
    calendar_colors = {},
    countdown = {
        enabled = true,
        seconds = 30,
        final_timeout = 10000,
    },
    keymaps = {
        close = "q",
        prev_week = { "h", "<Left>" },
        next_week = { "l", "<Right>" },
        today = { "t", "=" },
        refresh = "r",
        open_url = "<CR>",
        hover = "K",
        next_event = "n",
        prev_event = "N",
        open_gcal = "o",
    },
}

---@type GcalDefaults
M.options = {}

---Setup gcal.nvim configuration by deep-extending the defaults with user opts.
---@param opts table|nil
function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
end

return M
