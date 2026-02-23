# Contributing to gcal-nvim

## Running the tests

### Prerequisites

[busted](https://lunarmodules.github.io/busted/) must be on your `PATH`.
Install it once with luarocks:

```sh
luarocks install busted
```

On macOS with Homebrew the binary lands at `/opt/homebrew/bin/busted`.

### Running all tests

```sh
make test
```

Or call busted directly:

```sh
busted
```

### Running a single spec file

```sh
make test-file FILE=spec/utils_spec.lua
# or
busted spec/utils_spec.lua
```

## Test layout

```
spec/
├── support/
│   ├── init.lua        # bootstrap: adds lua/ to package.path, injects vim stub
│   └── vim_stub.lua    # minimal vim.* shim so modules load outside Neovim
├── utils_spec.lua      # url_encode/decode, ISO8601, week bounds, truncate, …
├── config_spec.lua     # defaults, setup() merging
├── cache_spec.lua      # memory + disk cache: get/set/invalidate/TTL
└── colors_spec.lua     # highlight assignment, palette wrapping, fallbacks
```

Tests are plain Lua 5.4 and run with the system `lua` interpreter via busted —
**no Neovim process is required**.  
Modules that call `vim.*` APIs use the stub defined in `spec/support/vim_stub.lua`.

## Adding a new spec

1. Create `spec/<module>_spec.lua`.
2. Start the file with `require("spec.support.init")` so the plugin modules are
   resolvable.
3. Use standard busted `describe` / `it` / `assert` blocks.
4. Run `make test` to confirm everything is green before opening a PR.
