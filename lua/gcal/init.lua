local config = require("gcal.config")
local auth = require("gcal.auth")
local ui = require("gcal.ui")
local notify = require("gcal.notify")

local M = {}

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("GcalAuth", function()
    auth.authenticate()
  end, { desc = "Authenticate with Google Calendar" })

  vim.api.nvim_create_user_command("GcalOpen", function()
    ui.open()
  end, { desc = "Open Google Calendar week view" })

  vim.api.nvim_create_user_command("GcalRefresh", function()
    ui.refresh()
  end, { desc = "Refresh calendar events" })

  vim.api.nvim_create_user_command("GcalToday", function()
    ui.today()
    if not ui.open then
      ui.open()
    end
  end, { desc = "Jump to current week" })

  vim.api.nvim_create_user_command("GcalNow", function()
    ui.goto_current_meeting()
  end, { desc = "Jump to current or next upcoming meeting" })

  vim.api.nvim_create_user_command("GcalAlerts", function(cmd)
    local arg = cmd.args:lower()
    if arg == "on" then
      notify.toggle(true)
    elseif arg == "off" then
      notify.toggle(false)
    else
      notify.toggle()
    end
  end, { nargs = "?", desc = "Toggle calendar alerts (on/off)" })

  if config.options.alerts_enabled then
    vim.api.nvim_create_autocmd("VimEnter", {
      callback = function()
        local tokens = auth.get_tokens()
        if tokens then
          notify.start()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      notify.stop()
    end,
  })
end

return M
