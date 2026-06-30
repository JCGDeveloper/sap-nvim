#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="${SAP_NVIM_VALIDATE_LOG_DIR:-/tmp/sap-nvim-validate-local}"
STATE_DIR="$LOG_DIR/state"
SHADA_FILE="$LOG_DIR/shada"
mkdir -p "$LOG_DIR" "$STATE_DIR"

FAILED=0
STEP=0

have() {
  command -v "$1" >/dev/null 2>&1
}

run_step() {
  STEP=$((STEP + 1))
  local name="$1"
  shift
  local log="$LOG_DIR/$(printf '%02d' "$STEP")-${name//[^A-Za-z0-9_.-]/_}.log"

  printf '\n[%02d] %s\n' "$STEP" "$name"
  printf '     $ %s\n' "$*"

  "$@" >"$log" 2>&1
  local status=$?

  if [ "$status" -eq 0 ]; then
    printf '     OK  status=%s log=%s\n' "$status" "$log"
  else
    printf '     FAIL status=%s log=%s\n' "$status" "$log"
    tail -n 40 "$log" | sed 's/^/     | /'
    FAILED=1
  fi
}

run_shell_step() {
  STEP=$((STEP + 1))
  local name="$1"
  local command="$2"
  local log="$LOG_DIR/$(printf '%02d' "$STEP")-${name//[^A-Za-z0-9_.-]/_}.log"

  printf '\n[%02d] %s\n' "$STEP" "$name"
  printf '     $ %s\n' "$command"

  bash -lc "$command" >"$log" 2>&1
  local status=$?

  if [ "$status" -eq 0 ]; then
    printf '     OK  status=%s log=%s\n' "$status" "$log"
  else
    printf '     FAIL status=%s log=%s\n' "$status" "$log"
    tail -n 40 "$log" | sed 's/^/     | /'
    FAILED=1
  fi
}

printf 'sap-nvim local validation\n'
printf 'repo: %s\n' "$ROOT"
printf 'logs: %s\n' "$LOG_DIR"
printf 'scope: local/offline only; no SAP commands are executed\n'

run_step "git status --short" git status --short
run_step "git diff --check" git diff --check

for tool in git nvim luajit python3; do
  if have "$tool"; then
    run_shell_step "tool $tool" "command -v $tool && $tool --version 2>/dev/null | head -n 3 || true"
  else
    printf '\n[--] tool %s\n     FAIL missing required command\n' "$tool"
    FAILED=1
  fi
done

for tool in node npm sapcli abaplint rg; do
  if have "$tool"; then
    run_shell_step "tool $tool" "command -v $tool && $tool --version 2>/dev/null | head -n 3 || true"
  else
    printf '\n[--] tool %s\n     WARN optional command not found\n' "$tool"
  fi
done

if [ -x test/run_offline.sh ]; then
  run_step "offline tests" bash test/run_offline.sh
else
  printf '\n[--] offline tests\n     FAIL test/run_offline.sh is missing or not executable\n'
  FAILED=1
fi

run_step "headless plugin load" \
  env XDG_STATE_HOME="$STATE_DIR" \
  nvim --headless -u NONE -i "$SHADA_FILE" \
  +"set rtp+=$ROOT" \
  +'lua require("sap-nvim").setup(); print("LOAD_OK")' +qa

printf '\nSummary\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'OK: local validation passed. Logs are in %s\n' "$LOG_DIR"
else
  printf 'FAIL: local validation found errors. Inspect logs in %s\n' "$LOG_DIR"
fi

exit "$FAILED"
