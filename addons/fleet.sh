#!/usr/bin/env bash
# fleet.sh — setup/teardown helper for Add-on 01 (Clone Fleet).
#
# Creates the three clone-mode sandboxes the add-on launches in parallel:
# svc-vote, svc-result, svc-gateway. `sbx run NAME` only attaches to a sandbox
# that already exists (NAME must otherwise be a known agent like `claude`), so
# the fleet has to be created first — that is what this script does.
#
# Usage: ./addons/fleet.sh [setup|status|reset]
#   setup  — create the three clone sandboxes (idempotent; skips any that exist)
#   status — show the fleet's sandboxes
#   reset  — remove the sandboxes, their sandbox-* git remotes, and fleet/* branches
#
# After `setup`, launch each agent in its own terminal tab (see the add-on):
#   sbx run svc-vote -- --dangerously-skip-permissions "<prompt>"

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The fleet: one clone-mode sandbox per service.
FLEET=(svc-vote svc-result svc-gateway)

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
# Subcommand: setup
# ---------------------------------------------------------------------------
cmd_setup() {
  echo "=== fleet setup: creating ${#FLEET[@]} clone sandboxes ==="
  echo

  for name in "${FLEET[@]}"; do
    # ▶ host-validate
    if sbx ls --quiet 2>/dev/null | grep -qx "$name"; then
      ok "Sandbox '$name' already exists — skipping"
      continue
    fi
    # ▶ host-validate — clone mode: agent works on an in-VM clone; the host tree
    # is NOT bind-mounted. `--clone` must be set at creation time.
    sbx create --name "$name" --clone claude "$REPO_ROOT"
    ok "Created clone sandbox '$name'"
  done

  echo
  ok "Fleet ready."
  info "Launch each agent in its own terminal tab:"
  info ""
  info "  sbx run svc-vote    -- --dangerously-skip-permissions '<vote prompt>'"
  info "  sbx run svc-result  -- --dangerously-skip-permissions '<result prompt>'"
  info "  sbx run svc-gateway -- --dangerously-skip-permissions '<gateway prompt>'"
  info ""
  info "Exact prompts are in addons/01-clone-fleet.md (Step 1)."
}

# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------
cmd_status() {
  echo "=== fleet status ==="
  # ▶ host-validate
  local listing
  listing="$(sbx ls 2>/dev/null || true)"
  printf "%s\n" "$listing" | head -1   # header row
  for name in "${FLEET[@]}"; do
    if printf "%s\n" "$listing" | awk '{print $1}' | grep -qx "$name"; then
      printf "%s\n" "$listing" | awk -v n="$name" '$1 == n'
    else
      warn "$name — not created (run './addons/fleet.sh setup')"
    fi
  done
}

# ---------------------------------------------------------------------------
# Subcommand: reset
# ---------------------------------------------------------------------------
cmd_reset() {
  echo "=== fleet reset: tearing down sandboxes, remotes, and branches ==="
  echo

  # 1. Remove the sandboxes (only those that exist).
  local existing=()
  for name in "${FLEET[@]}"; do
    # ▶ host-validate
    if sbx ls --quiet 2>/dev/null | grep -qx "$name"; then
      existing+=("$name")
    fi
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    # ▶ host-validate — --force skips sbx's per-sandbox confirmation prompt
    sbx rm --force "${existing[@]}"
    ok "Removed sandboxes: ${existing[*]}"
  else
    ok "No fleet sandboxes to remove"
  fi

  # 2. Remove the sandbox-<name> git remotes sbx registered on the host repo.
  for name in "${FLEET[@]}"; do
    if git -C "$REPO_ROOT" remote get-url "sandbox-$name" &>/dev/null; then
      git -C "$REPO_ROOT" remote remove "sandbox-$name"
      ok "Removed git remote 'sandbox-$name'"
    fi
  done

  # 3. Remove local fleet/* tracking branches.
  local fleet_branches
  fleet_branches="$(git -C "$REPO_ROOT" branch --list 'fleet/*')"
  if [[ -n "$fleet_branches" ]]; then
    echo "$fleet_branches" | sed 's/^[* ]*//' | xargs -r git -C "$REPO_ROOT" branch -D
    ok "Deleted fleet/* branches"
  else
    ok "No fleet/* branches to delete"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ./addons/fleet.sh [setup|status|reset]

  setup  — create the three clone sandboxes (svc-vote, svc-result, svc-gateway)
  status — show the fleet's sandboxes
  reset  — remove the sandboxes, sandbox-* git remotes, and fleet/* branches
EOF
}

case "${1:-}" in
  setup)  cmd_setup  ;;
  status) cmd_status ;;
  reset)  cmd_reset  ;;
  *)      usage; exit 1 ;;
esac
