.PHONY: test lint

# Run the full test suite with busted.
# Requires: luarocks install busted   (already in PATH at /opt/homebrew/bin/busted)
test:
	busted

# Run a single spec file, e.g.:  make test-file FILE=spec/utils_spec.lua
test-file:
	busted $(FILE)
