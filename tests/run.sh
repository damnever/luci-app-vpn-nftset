#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
if [ -z "${VPN_NFTSET_LUA:-}" ]; then
    VPN_NFTSET_LUA=$(command -v lua || command -v luajit || true)
fi
if [ -z "$VPN_NFTSET_LUA" ]; then
    echo "Lua 5.1 or LuaJIT is required to run the tests." >&2
    exit 1
fi
export VPN_NFTSET_LUA

"$VPN_NFTSET_LUA" tests/test_domains.lua
"$VPN_NFTSET_LUA" tests/render_ui.lua test
"$VPN_NFTSET_LUA" tests/test_ui_controller.lua
python3 -m unittest discover -s tests -p 'test_*.py'
node --test tests/test_ui.js
