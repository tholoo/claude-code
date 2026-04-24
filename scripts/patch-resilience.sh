#!/usr/bin/env bash
# patch-resilience.sh — Patch claude-code's cli.js for flaky/censored networks
#
# Applies four patches to the bundled cli.js:
#   1. API client maxRetries: 2 → 999 (effectively unlimited retries)
#   2. SSE reconnection: faster initial retry, lower backoff cap, ~unlimited budget
#   3. Stream idle timeout default: 90s → ~infinite
#   4. SSE liveness timeout: 45s → 600s (10 min tolerance for stalls)
#
# Usage:
#   ./scripts/patch-resilience.sh <path-to-cli.js>
#   ./scripts/patch-resilience.sh                   # auto-detect installed cli.js
#
# Idempotent — safe to re-run on an already-patched file.
#
# The companion script claude-proxy-wrapper.sh handles HTTP/SOCKS proxy setup
# via settings.json proxyUrl and env vars (no cli.js patching needed for that).

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { printf "${GREEN}[patch]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[patch]${NC} %s\n" "$*"; }
err()   { printf "${RED}[patch]${NC} %s\n" "$*" >&2; }

# --- Locate cli.js -----------------------------------------------------------

find_cli_js() {
  # Follow the claude binary symlink
  if command -v claude &>/dev/null; then
    local bin
    bin="$(readlink -f "$(command -v claude)" 2>/dev/null || true)"
    if [[ -n "$bin" ]]; then
      local pkg_dir
      pkg_dir="$(dirname "$bin")/../lib/node_modules/@anthropic-ai/claude-code"
      if [[ -f "$pkg_dir/cli.js" ]]; then
        echo "$pkg_dir/cli.js"
        return 0
      fi
    fi
  fi

  # npm global
  local npm_root
  npm_root="$(npm root -g 2>/dev/null || true)"
  if [[ -n "$npm_root" && -f "$npm_root/@anthropic-ai/claude-code/cli.js" ]]; then
    echo "$npm_root/@anthropic-ai/claude-code/cli.js"
    return 0
  fi

  return 1
}

CLI_JS="${1:-}"
if [[ -z "$CLI_JS" ]]; then
  CLI_JS="$(find_cli_js)" || {
    err "Could not locate cli.js. Pass the path as an argument."
    exit 1
  }
fi

if [[ ! -f "$CLI_JS" ]]; then
  err "File not found: $CLI_JS"
  exit 1
fi

info "Patching: $CLI_JS"

if [[ ! -w "$CLI_JS" ]]; then
  err "File is not writable: $CLI_JS"
  err "If this is a Nix store path, copy it first or use the Nix overlay."
  exit 1
fi

# --- Patch helpers ------------------------------------------------------------

patched=0
skipped=0
failed=0

# Bash arithmetic returns exit 1 when result is 0, which trips set -e.
inc_patched() { patched=$((patched + 1)); }
inc_skipped() { skipped=$((skipped + 1)); }
inc_failed()  { failed=$((failed + 1)); }

# replace_literal DESCRIPTION OLD_STRING NEW_STRING
# Uses perl for literal (non-regex) string replacement.
replace_literal() {
  local desc="$1" old="$2" new="$3"

  if [[ "$old" == "$new" ]]; then
    warn "  – $desc (old == new, nothing to do)"
    inc_skipped
    return
  fi

  if grep -qF "$old" "$CLI_JS"; then
    perl -pi -e "
      BEGIN { \$old = shift; \$new = shift; }
      s/\Q\$old/\$new/g;
    " "$old" "$new" "$CLI_JS"
    info "  ✓ $desc"
    inc_patched
  elif grep -qF "$new" "$CLI_JS"; then
    warn "  – $desc (already applied)"
    inc_skipped
  else
    warn "  ✗ $desc (pattern not found — cli.js version may differ)"
    inc_failed
  fi
}

# --- 1. Increase API maxRetries ----------------------------------------------

info "1/4 API maxRetries"

# The Anthropic SDK client constructor: this.maxRetries=Y.maxRetries??2
# We can't match the exact variable name (it changes per build), so we find it.
max_retries_match=$(grep -oP 'this\.maxRetries=[A-Za-z0-9_.]+\?\?\K\d+' "$CLI_JS" | head -1 || true)

if [[ "$max_retries_match" == "2" ]]; then
  # Get the full match to do literal replacement
  full_match=$(grep -oP 'this\.maxRetries=[A-Za-z0-9_.]+\?\?2' "$CLI_JS" | head -1)
  new_match="${full_match/%??2/??999}"
  replace_literal "maxRetries: 2 → 999" "$full_match" "$new_match"
elif [[ "$max_retries_match" == "999" ]]; then
  warn "  – maxRetries already set to 999"
  inc_skipped
elif [[ -n "$max_retries_match" ]]; then
  warn "  – maxRetries has unexpected value: $max_retries_match"
  inc_failed
else
  warn "  ✗ maxRetries pattern not found"
  inc_failed
fi

# --- 2. SSE reconnection tuning ----------------------------------------------

info "2/4 SSE reconnection parameters"
replace_literal \
  "SSE defaults: faster retry, lower cap, ~unlimited retries" \
  'initialReconnectionDelay:1000,maxReconnectionDelay:30000,reconnectionDelayGrowFactor:1.5,maxRetries:2' \
  'initialReconnectionDelay:300,maxReconnectionDelay:8000,reconnectionDelayGrowFactor:1.5,maxRetries:999'

# --- 3. Stream idle timeout ---------------------------------------------------

info "3/4 Stream idle timeout default"
# parseInt(env.CLAUDE_STREAM_IDLE_TIMEOUT_MS || "", 10) || 90000
replace_literal \
  "idle timeout fallback: 90s → ~infinite" \
  'CLAUDE_STREAM_IDLE_TIMEOUT_MS||"",10)||90000' \
  'CLAUDE_STREAM_IDLE_TIMEOUT_MS||"",10)||999999999'

# --- 4. SSE liveness timeout -------------------------------------------------

info "4/4 SSE liveness timeout"

# Find the variable name from: setTimeout(this.onLivenessTimeout,VAR_NAME)
liveness_var=$(grep -oP '(?<=setTimeout\(this\.onLivenessTimeout,)[A-Za-z0-9_]+' "$CLI_JS" | head -1 || true)

if [[ -n "$liveness_var" ]]; then
  current_val=$(grep -oP "(?<=${liveness_var}=)\\d+" "$CLI_JS" | head -1 || true)
  if [[ "$current_val" == "45000" ]]; then
    replace_literal \
      "liveness timeout ($liveness_var): 45s → 600s" \
      "${liveness_var}=45000" \
      "${liveness_var}=600000"
  elif [[ "$current_val" == "600000" ]]; then
    warn "  – liveness timeout already set to 600s"
    inc_skipped
  else
    warn "  – liveness timeout ($liveness_var) has unexpected value: ${current_val:-unknown}"
    inc_failed
  fi
else
  warn "  ✗ Could not identify liveness timeout variable"
  inc_failed
fi

# --- Summary ------------------------------------------------------------------

echo ""
if ((failed > 0)); then
  err "Done: $patched applied, $skipped already applied, $failed failed."
  exit 1
elif ((patched > 0)); then
  info "Done: $patched patch(es) applied, $skipped already applied."
else
  info "Done: all patches already applied ($skipped skipped)."
fi
