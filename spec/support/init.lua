-- spec/support/init.lua
-- Bootstrap: make gcal modules resolvable and inject the vim stub.

local root = debug.getinfo(1, "S").source:match("^@(.+)/spec/support/init%.lua$")
  or vim.fn and vim.fn.getcwd()  -- fallback when run inside Neovim
  or "."

-- Add plugin lua/ dir to package.path so require("gcal.xxx") works.
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Inject the vim stub if we are NOT running inside Neovim.
if not rawget(_G, "vim") then
  _G.vim = require("spec.support.vim_stub")
end
