#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

find lua -name '*.lua' -print0 | xargs -0 -I{} luajit -b {} /tmp/sap-nvim-luac-check.out
python3 -m py_compile python/adt_daemon.py

luajit test/completion_spec.lua
luajit test/sapcli_gate_spec.lua
luajit test/sapcli_productive_gate_spec.lua
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/quality_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/ux_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/dumps_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/revisions_spec.lua +qa!

env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/adt_http_plaintext_password_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/productive_config_status_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/adt_http_productive_gate_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/new_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/index_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/index_consumers_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/quickfix_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/refactor_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/source_package_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/activation_check_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/docs_panel_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/transport_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/sapcli_auth_gate_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/debugger_cockpit_spec.lua
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada -S test/repository_spec.lua +qa!
env XDG_STATE_HOME=/tmp/sap-nvim-state nvim --headless -u NONE -i /tmp/sap-nvim-shada +'set rtp+=.' +'lua require("sap-nvim").setup(); print("LOAD_OK")' +qa

echo "sap-nvim offline tests OK"
