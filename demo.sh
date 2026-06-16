#!/usr/bin/env bash
# demo.sh — lifecycle helper for the sbx-enterprise-demo sandbox.
#
# Usage: ./demo.sh [prep|check|reset]
#   prep   — create the demo sandbox and ensure everything is ready
#   check  — verify the sandbox is running and services are reachable
#   reset  — tear down and recreate for a clean run

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SANDBOX_NAME="demo-agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

ok()   { printf "${GREEN}[OK]${RESET}   %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
info() { printf "       %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Subcommand: prep
# ---------------------------------------------------------------------------
cmd_prep() {
  echo "=== prep: verifying host prerequisites ==="

  # 1. Check required tools are in PATH
  local missing=0
  for tool in sbx gh docker go node python3; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool found ($(command -v "$tool"))"
    else
      fail "$tool not found in PATH"
      missing=$((missing + 1))
    fi
  done
  if [[ $missing -gt 0 ]]; then
    fail "$missing required tool(s) missing — install them and re-run prep"
    exit 1
  fi

  # 2. Check working tree state
  echo
  echo "=== prep: checking git working tree ==="
  local dirty
  dirty="$(git -C "$REPO_ROOT" status --short)"
  if [[ -n "$dirty" ]]; then
    warn "Working tree has uncommitted changes:"
    while IFS= read -r line; do
      warn "  $line"
    done <<<"$dirty"
    warn "Continuing, but the sandbox will see the committed state."
  else
    ok "Working tree is clean"
  fi

  # 3. Create the sandbox (idempotent — skip if already exists)
  echo
  echo "=== prep: creating sandbox '$SANDBOX_NAME' ==="
  if sbx ls --quiet 2>/dev/null | grep -qx "$SANDBOX_NAME"; then  # ▶ host-validate
    ok "Sandbox '$SANDBOX_NAME' already exists — skipping creation"
  else
    # ▶ host-validate — `sbx create AGENT PATH`: claude agent, repo root as workspace
    sbx create --name "$SANDBOX_NAME" claude "$REPO_ROOT"
    ok "Sandbox '$SANDBOX_NAME' created"
  fi

  # 4. Print usage hint
  echo
  ok "Ready!"
  info "To start an agent session, run on the host:"
  info ""
  info "  sbx run $SANDBOX_NAME -- --dangerously-skip-permissions '<prompt>'"
  info ""
  info "Replace <prompt> with your task description."
}

# ---------------------------------------------------------------------------
# Subcommand: check
# ---------------------------------------------------------------------------
cmd_check() {
  echo "=== check: verifying sandbox status ==="

  # 1. Confirm sandbox exists
  # ▶ host-validate
  if sbx ls --quiet 2>/dev/null | grep -qx "$SANDBOX_NAME"; then
    ok "Sandbox '$SANDBOX_NAME' is running"
  else
    fail "Sandbox '$SANDBOX_NAME' is not running — run './demo.sh prep' first"
    exit 1
  fi

  # 2. Verify services compile / parse correctly
  echo
  echo "=== check: verifying service source ==="

  # Go gateway
  local gateway_dir="$REPO_ROOT/services/gateway"
  if [[ -d "$gateway_dir" ]]; then
    if (cd "$gateway_dir" && go build ./... 2>&1); then
      ok "services/gateway: go build ./... succeeded"
    else
      fail "services/gateway: go build ./... failed"
      exit 1
    fi
  else
    warn "services/gateway directory not found — skipping Go build check"
  fi

  # Node result service
  local result_js="$REPO_ROOT/services/result/server.js"
  if [[ -f "$result_js" ]]; then
    if node --check "$result_js" 2>&1; then
      ok "services/result/server.js: node --check passed"
    else
      fail "services/result/server.js: node --check failed"
      exit 1
    fi
  else
    warn "services/result/server.js not found — skipping Node check"
  fi

  # Python vote service
  local vote_py="$REPO_ROOT/services/vote/app.py"
  if [[ -f "$vote_py" ]]; then
    if python3 -m py_compile "$vote_py" 2>&1; then
      ok "services/vote/app.py: py_compile passed"
    else
      fail "services/vote/app.py: py_compile failed"
      exit 1
    fi
  else
    warn "services/vote/app.py not found — skipping Python check"
  fi

  # Summary
  echo
  printf "${GREEN}================================================${RESET}\n"
  printf "${GREEN}  All checks passed. Demo environment is ready.${RESET}\n"
  printf "${GREEN}================================================${RESET}\n"
}

# ---------------------------------------------------------------------------
# Subcommand: reset
# ---------------------------------------------------------------------------
cmd_reset() {
  echo "=== reset: tearing down sandbox '$SANDBOX_NAME' ==="

  # 1. Confirmation prompt unless FORCE=1
  if [[ "${FORCE:-0}" != "1" ]]; then
    printf "${YELLOW}This will delete sandbox '%s' and all its state.${RESET}\n" "$SANDBOX_NAME"
    printf "Type 'yes' to continue, or anything else to abort: "
    read -r answer
    if [[ "$answer" != "yes" ]]; then
      info "Aborted. Set FORCE=1 to skip this prompt."
      exit 0
    fi
  else
    warn "FORCE=1 set — skipping confirmation prompt"
  fi

  # ▶ host-validate
  if sbx ls --quiet 2>/dev/null | grep -qx "$SANDBOX_NAME"; then
    # ▶ host-validate — --force: this script already prompted above, so skip sbx's own prompt
    sbx rm --force "$SANDBOX_NAME"
    ok "Sandbox '$SANDBOX_NAME' removed"
  else
    warn "Sandbox '$SANDBOX_NAME' was not running — nothing to delete"
  fi

  # 2. Clean up leftover fleet/* branches from the clone-fleet add-on
  echo
  echo "=== reset: cleaning up fleet/* branches ==="
  local fleet_branches
  fleet_branches="$(git -C "$REPO_ROOT" branch --list 'fleet/*')"
  if [[ -n "$fleet_branches" ]]; then
    echo "$fleet_branches" | xargs -r git -C "$REPO_ROOT" branch -D
    ok "Deleted leftover fleet/* branches"
  else
    ok "No fleet/* branches to clean up"
  fi

  # 3. Re-run prep
  echo
  echo "=== reset: running prep ==="
  cmd_prep
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ./demo.sh [prep|check|reset]

  prep   — create the demo sandbox and ensure everything is ready
  check  — verify the sandbox is running and services are reachable
  reset  — tear down and recreate for a clean run

Environment variables:
  FORCE=1   Skip the confirmation prompt in 'reset'
EOF
}

case "${1:-}" in
  prep)  cmd_prep  ;;
  check) cmd_check ;;
  reset) cmd_reset ;;
  *)     usage; exit 1 ;;
esac
