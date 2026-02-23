-- spec/support/vim_stub.lua
-- Minimal vim-API stub so gcal modules can be require()'d outside Neovim.
-- Only the symbols actually used by the tested modules are provided.

local _hl = {}

local vim_stub = {
  -- ── tables ────────────────────────────────────────────────────────────────
  tbl_deep_extend = function(mode, ...)
    local result = {}
    local function deep_extend(t)
      for k, v in pairs(t) do
        if type(v) == "table" and type(result[k]) == "table" then
          -- recurse
          local sub = {}
          for kk, vv in pairs(result[k]) do sub[kk] = vv end
          for kk, vv in pairs(v) do
            if type(vv) == "table" and type(sub[kk]) == "table" then
              -- one more level (sufficient for config.defaults depth)
              local subsub = {}
              for kkk, vvv in pairs(sub[kk]) do subsub[kkk] = vvv end
              for kkk, vvv in pairs(vv) do subsub[kkk] = vvv end
              sub[kk] = subsub
            else
              sub[kk] = vv
            end
          end
          result[k] = sub
        else
          result[k] = v
        end
      end
    end
    for i = 1, select("#", ...) do
      local t = select(i, ...)
      if t then deep_extend(t) end
    end
    return result
  end,

  json = {
    encode = function(v)
      -- Delegate to dkjson if available, otherwise a very small fallback.
      local ok, dkjson = pcall(require, "dkjson")
      if ok then return dkjson.encode(v) end
      -- Tiny fallback for basic types
      if type(v) == "nil" then return "null" end
      if type(v) == "boolean" then return tostring(v) end
      if type(v) == "number" then return tostring(v) end
      if type(v) == "string" then
        return '"' .. v:gsub('"', '\\"') .. '"'
      end
      if type(v) == "table" then
        local parts = {}
        local is_array = (#v > 0)
        if is_array then
          for _, val in ipairs(v) do
            table.insert(parts, vim_stub.json.encode(val))
          end
          return "[" .. table.concat(parts, ",") .. "]"
        else
          for k, val in pairs(v) do
            table.insert(parts, '"' .. k .. '":' .. vim_stub.json.encode(val))
          end
          return "{" .. table.concat(parts, ",") .. "}"
        end
      end
      return "null"
    end,
    decode = function(s)
      local ok, dkjson = pcall(require, "dkjson")
      if ok then return dkjson.decode(s) end
      error("vim.json.decode stub: dkjson not available")
    end,
  },

  fn = {
    stdpath = function(what)
      if what == "data" then return "/tmp/gcal_test_data" end
      if what == "cache" then return "/tmp/gcal_test_cache" end
      return "/tmp/gcal_test_" .. what
    end,
    fnamemodify = function(path, mods)
      if mods == ":h" then
        -- Return the directory part
        return path:match("^(.*)/[^/]*$") or "."
      end
      return path
    end,
    isdirectory = function(path)
      -- Use io.open as a proxy
      local f = io.popen('[ -d "' .. path .. '" ] && echo 1 || echo 0')
      if not f then return 0 end
      local r = f:read("*l")
      f:close()
      return tonumber(r) or 0
    end,
    mkdir = function(path, flags)
      os.execute('mkdir -p "' .. path .. '"')
    end,
    filereadable = function(path)
      local f = io.open(path, "r")
      if f then f:close(); return 1 end
      return 0
    end,
    readfile = function(path)
      local f = io.open(path, "r")
      if not f then return nil end
      local lines = {}
      for line in f:lines() do table.insert(lines, line) end
      f:close()
      return lines
    end,
    writefile = function(lines, path)
      local f = io.open(path, "w")
      if not f then return end
      for _, line in ipairs(lines) do
        f:write(line .. "\n")
      end
      f:close()
    end,
    delete = function(path)
      os.remove(path)
    end,
  },

  -- ── highlight API (no-ops for unit tests) ─────────────────────────────────
  api = {
    nvim_set_hl = function(ns, name, opts)
      _hl[name] = opts
    end,
    nvim_get_hl = function(ns, opts)
      return _hl[opts.name] or {}
    end,
  },

  -- Expose the hl table for assertions
  _hl = _hl,
}

return vim_stub
