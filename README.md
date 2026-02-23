# gcal.nvim

Google Calendar inside Neovim — week view with per-calendar colors, meeting alerts, and countdown notifications.

## Features

- **Week view** — floating window with a Google Calendar-style grid layout
- **Per-calendar colors** — each calendar gets its own highlight group
- **Event hover popup** — press `K` to see title, time range, calendar, time-until, meeting URL, location, and description
- **Open meeting URL** — press `<CR>` to open the Zoom/Meet/Teams link directly in your browser
- **Jump to meeting** — `:GcalNow` opens the current or next meeting URL; shows a picker if multiple meetings overlap
- **Event navigation** — `n`/`N` jump to the next/previous event, crossing day and week boundaries
- **Meeting alerts** — configurable notifications at N minutes before events
- **Countdown** — live 30-second countdown with in-place notification updates before meetings start
- **Smart caching** — current and next week are cached locally; older weeks are fetched live

## Requirements

- Neovim ≥ 0.10
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nvim-notify](https://github.com/rcarriga/nvim-notify)

## Setup

### 1. Create Google Cloud credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Click **Select a project** → **New project**, give it a name, click **Create**
3. With the project selected, go to **APIs & Services** → **Library**
4. Search for **Google Calendar API** and click **Enable**
5. Go to **APIs & Services** → **OAuth consent screen**
   - User type: **External**
   - Fill in app name and support email, click **Save and Continue** through the remaining steps
   - On the **Test users** step, add your Google account email
6. Go to **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth 2.0 Client ID**
   - Application type: **Desktop app**
   - Click **Create**
7. Copy the **Client ID** and **Client Secret** shown in the dialog

### 2. Install the plugin

Install directly from GitHub — replace `OWNER` with the GitHub user or organization that hosts the repo (for example, `your-github-username/gcal.nvim`).

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
  {
  'gzitei/gcal.nvim',
  dependencies = { 'nvim-lua/plenary.nvim', 'rcarriga/nvim-notify' },
  opts = {
    client_id = 'YOUR_CLIENT_ID',
    client_secret = 'YOUR_CLIENT_SECRET',
  },
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  'gzitei/gcal.nvim',
  requires = { 'nvim-lua/plenary.nvim', 'rcarriga/nvim-notify' },
  config = function()
    require('gcal').setup({
      client_id = 'YOUR_CLIENT_ID',
      client_secret = 'YOUR_CLIENT_SECRET',
    })
  end,
}
```

### 3. Authenticate

Run `:GcalAuth` in Neovim. Your browser will open the Google OAuth consent page. Sign in, grant access, and return to Neovim — authentication is handled automatically. Tokens are saved to disk and refreshed silently from that point on.

### 4. Open the calendar

```
:GcalOpen
```

## Commands

| Command | Description |
|---|---|
| `:GcalAuth` | Authenticate with Google |
| `:GcalOpen` | Open the week view |
| `:GcalRefresh` | Re-fetch events in the current view |
| `:GcalToday` | Jump to the current week |
| `:GcalNow` | Open the URL of the current or next meeting in your browser |
| `:GcalAlerts on\|off` | Toggle meeting alerts |

## Week View Keymaps

| Key | Action |
|---|---|
| `h` | Previous week |
| `l` | Next week |
| `t` / `=` | Jump to today |
| `n` | Jump to next event (crosses weeks) |
| `N` | Jump to previous event (crosses weeks) |
| `K` | Show event details popup |
| `<CR>` | Open meeting URL in browser |
| `r` | Force refresh events |
| `q` | Close |

## Configuration

All options with their defaults:

```lua
require('gcal').setup({
  client_id = '',               -- optional: if empty, you will be prompted
  client_secret = '',           -- optional: if empty, you will be prompted
  calendars = {},               -- {} = all calendars; or list of calendar IDs
  alert_minutes = { 15, 5 },    -- notify at these minutes before events
  alerts_enabled = true,
  poll_interval_seconds = 60,
  week_start = 'monday',        -- or 'sunday'
  time_format = '24h',          -- or '12h'
  view = {
    float = true,
    width = 0.85,               -- percentage of editor width
    height = 0.85,              -- percentage of editor height
    day_start_hour = 7,
    day_end_hour = 19,
  },
  auth = {
    port = 8234,                -- localhost port for OAuth callback
    token_path = vim.fn.stdpath('data') .. '/gcal/tokens.json',
  },
  calendar_colors = {},         -- override: { ['calendar_id'] = '#ff0000' }
  countdown = {
    enabled = true,
    seconds = 30,               -- start countdown this many seconds before event
    final_timeout = 10000,      -- ms to keep the "starting NOW" notification visible
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
  }
})
```

## Development

### Running tests

Requires [busted](https://lunarmodules.github.io/busted/):

```sh
luarocks install busted
```

Then run the full suite:

```sh
make test
```

Or a single spec file:

```sh
busted spec/utils_spec.lua
```

Tests run with plain Lua 5.4 — no Neovim process required. See [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

## License

MIT
