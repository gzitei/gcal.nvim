local curl = require("plenary.curl")
local config = require("gcal.config")
local utils = require("gcal.utils")

local M = {}

local GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
local GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
local SCOPES = table.concat({
  "https://www.googleapis.com/auth/calendar.readonly",
}, " ")

local function get_redirect_uri()
  return "http://localhost:" .. config.options.auth.port
end

local function get_credentials()
  local id = config.options.client_id
  local secret = config.options.client_secret

  local creds_path = vim.fn.stdpath("cache") .. "/gcal/credentials.json"
  if (not id or id == "") or (not secret or secret == "") then
    if vim.fn.filereadable(creds_path) == 1 then
      local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(creds_path), "\n"))
      if ok and data.client_id and data.client_secret then
        id = data.client_id
        secret = data.client_secret
      end
    end
  end

  if (not id or id == "") or (not secret or secret == "") then
    id = vim.fn.input("Google Calendar Client ID: ")
    if not id or id == "" then return nil, nil end
    secret = vim.fn.input("Google Calendar Client Secret: ")
    if not secret or secret == "" then return nil, nil end

    vim.fn.mkdir(vim.fn.stdpath("cache") .. "/gcal", "p")
    local ok, encoded = pcall(vim.json.encode, { client_id = id, client_secret = secret })
    if ok then
      vim.fn.writefile({ encoded }, creds_path)
    end
  end

  return id, secret
end

local function build_auth_url(client_id)
  local params = {
    client_id = client_id,
    redirect_uri = get_redirect_uri(),
    response_type = "code",
    scope = SCOPES,
    access_type = "offline",
    prompt = "consent",
  }
  local parts = {}
  for k, v in pairs(params) do
    table.insert(parts, k .. "=" .. utils.url_encode(v))
  end
  return GOOGLE_AUTH_URL .. "?" .. table.concat(parts, "&")
end

local function exchange_code(code, client_id, client_secret, callback)
  curl.post(GOOGLE_TOKEN_URL, {
    body = vim.json.encode({
      code = code,
      client_id = client_id,
      client_secret = client_secret,
      redirect_uri = get_redirect_uri(),
      grant_type = "authorization_code",
    }),
    headers = { content_type = "application/json" },
    callback = function(response)
      vim.schedule(function()
        if response.status ~= 200 then
          vim.notify("Failed to exchange auth code: " .. (response.body or ""), vim.log.levels.ERROR, { title = "gcal.nvim" })
          return
        end
        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          vim.notify("Failed to parse token response", vim.log.levels.ERROR, { title = "gcal.nvim" })
          return
        end
        data.expires_at = os.time() + (data.expires_in or 3600)
        utils.write_json(config.options.auth.token_path, data)
        vim.notify("Authentication successful!", vim.log.levels.INFO, { title = "gcal.nvim" })
        if callback then
          callback(data)
        end
      end)
    end,
  })
end

local function start_localhost_server(client_id, client_secret, callback)
  local uv = vim.uv or vim.loop
  local server = uv.new_tcp()
  server:bind("127.0.0.1", config.options.auth.port)

  server:listen(1, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to start auth server: " .. err, vim.log.levels.ERROR, { title = "gcal.nvim" })
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    client:read_start(function(read_err, data)
      if read_err or not data then
        client:close()
        server:close()
        return
      end

      local query = data:match("GET /%?(.+) HTTP")
      if not query then
        local error_response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<html><body><h1>Invalid request</h1></body></html>"
        client:write(error_response, function()
          client:close()
          server:close()
        end)
        return
      end

      local params = utils.parse_query_string(query)
      local html = [[<html><body style="font-family:sans-serif;text-align:center;padding-top:80px;">
<h1>gcal.nvim authenticated</h1><p>You can close this tab and return to Neovim.</p></body></html>]]
      local response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
        .. #html
        .. "\r\nConnection: close\r\n\r\n"
        .. html

      client:write(response, function()
        client:shutdown(function()
          client:close()
        end)
        server:close()
      end)

      if params.code then
        vim.schedule(function()
          exchange_code(params.code, client_id, client_secret, callback)
        end)
      elseif params.error then
        vim.schedule(function()
          vim.notify("Auth denied: " .. (params.error or "unknown"), vim.log.levels.ERROR, { title = "gcal.nvim" })
        end)
      end
    end)
  end)

  return server
end

function M.authenticate_oauth(callback)
  local id, secret = get_credentials()
  if not id or not secret then
    vim.notify("Client ID and Client Secret are required", vim.log.levels.ERROR, { title = "gcal.nvim" })
    return
  end

  start_localhost_server(id, secret, callback)

  local auth_url = build_auth_url(id)
  if vim.ui and vim.ui.open then
    vim.ui.open(auth_url)
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", auth_url }, { detach = true })
  elseif vim.fn.has("unix") == 1 then
    vim.fn.jobstart({ "xdg-open", auth_url }, { detach = true })
  else
    vim.notify("Open this URL in your browser:\n" .. auth_url, vim.log.levels.INFO, { title = "gcal.nvim" })
  end

  vim.notify("Waiting for Google authentication...", vim.log.levels.INFO, { title = "gcal.nvim" })
end

function M.authenticate_paste(callback)
  local playground_url = "https://developers.google.com/oauthplayground/#step1&scopes="
    .. utils.url_encode("https://www.googleapis.com/auth/calendar.readonly")
    .. "&url=https%3A%2F%2F&content_type=application%2Fjson&http_method=GET&useDefaultOauthCreds=checked"
  if vim.ui and vim.ui.open then
    vim.ui.open(playground_url)
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", playground_url }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", playground_url }, { detach = true })
  end
  vim.notify(
    "1. Click 'Authorize APIs'\n2. Click 'Exchange authorization code for tokens'\n3. Copy the token JSON and paste it below",
    vim.log.levels.INFO,
    { title = "gcal.nvim" }
  )

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "json")

  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(20, math.floor(vim.o.lines * 0.5))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Paste token JSON — <CR> to confirm, q to cancel ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function confirm()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local raw = table.concat(lines, "\n"):match("^%s*(.-)%s*$")
    close()

    if raw == "" then
      vim.notify("No token pasted", vim.log.levels.WARN, { title = "gcal.nvim" })
      return
    end

    local ok, data = pcall(vim.json.decode, raw)
    if not ok or type(data) ~= "table" then
      vim.notify("Invalid JSON — could not parse token", vim.log.levels.ERROR, { title = "gcal.nvim" })
      return
    end

    if not data.access_token then
      vim.notify("Token JSON must contain an 'access_token' field", vim.log.levels.ERROR, { title = "gcal.nvim" })
      return
    end

    if not data.expires_at then
      data.expires_at = os.time() + (data.expires_in or 3600)
    end

    utils.write_json(config.options.auth.token_path, data)
    vim.notify("Token saved successfully!", vim.log.levels.INFO, { title = "gcal.nvim" })

    if callback then
      callback(data)
    end
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", confirm, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)

  vim.cmd("startinsert")
end

function M.authenticate(callback)
  vim.ui.select(
    { "OAuth (client_id + client_secret)", "Paste token JSON" },
    { prompt = "Select authentication method:" },
    function(choice)
      if not choice then
        return
      end
      if choice == "OAuth (client_id + client_secret)" then
        M.authenticate_oauth(callback)
      else
        M.authenticate_paste(callback)
      end
    end
  )
end

function M.get_tokens()
  return utils.read_json(config.options.auth.token_path)
end

function M.refresh_token(callback)
  local tokens = M.get_tokens()
  if not tokens or not tokens.refresh_token then
    vim.notify("No refresh token found. Run :GcalAuth", vim.log.levels.ERROR, { title = "gcal.nvim" })
    return
  end

  local id, secret = get_credentials()
  if not id or not secret then return end

  curl.post(GOOGLE_TOKEN_URL, {
    body = vim.json.encode({
      client_id = id,
      client_secret = secret,
      refresh_token = tokens.refresh_token,
      grant_type = "refresh_token",
    }),
    headers = { content_type = "application/json" },
    callback = function(response)
      vim.schedule(function()
        if response.status ~= 200 then
          vim.notify("Token refresh failed", vim.log.levels.ERROR, { title = "gcal.nvim" })
          return
        end
        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          return
        end
        tokens.access_token = data.access_token
        tokens.expires_at = os.time() + (data.expires_in or 3600)
        if data.refresh_token then
          tokens.refresh_token = data.refresh_token
        end
        utils.write_json(config.options.auth.token_path, tokens)
        if callback then
          callback(tokens)
        end
      end)
    end,
  })
end

function M.get_access_token(callback)
  local tokens = M.get_tokens()
  if not tokens then
    vim.notify("Not authenticated. Run :GcalAuth", vim.log.levels.WARN, { title = "gcal.nvim" })
    return
  end
  if tokens.expires_at and os.time() >= tokens.expires_at - 60 then
    M.refresh_token(function(refreshed)
      callback(refreshed.access_token)
    end)
  else
    callback(tokens.access_token)
  end
end

return M
