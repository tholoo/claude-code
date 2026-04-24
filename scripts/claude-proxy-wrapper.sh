#!/usr/bin/env bash
# claude-proxy-wrapper.sh — Wrapper that sets up proxy env vars before launching claude
#
# Reads proxyUrl from ~/.claude/settings.local.json or ~/.claude/settings.json
# and exports HTTP_PROXY / HTTPS_PROXY / ALL_PROXY if the proxy is reachable.
#
# Supports http://, https://, socks5://, socks5h://, socks4:// URLs.
#
# Also sets CLAUDE_STREAM_IDLE_TIMEOUT_MS for flaky connections.
#
# Usage:
#   ./scripts/claude-proxy-wrapper.sh [claude args...]
#   # Or symlink/alias this as 'claude'
#
# The script finds the real 'claude' binary by skipping itself in PATH.

set -euo pipefail

CFG_DIR="${HOME}/.claude"
PROXY_URL=""

# --- Read proxy from settings -------------------------------------------------

for f in "${CFG_DIR}/settings.local.json" "${CFG_DIR}/settings.json"; do
  if [[ -z "$PROXY_URL" && -f "$f" ]]; then
    PROXY_URL="$(jq -r '.proxyUrl // empty' "$f" 2>/dev/null || true)"
  fi
done

# --- Set up proxy env vars ----------------------------------------------------

if [[ -n "$PROXY_URL" ]]; then
  # Parse host and port for connectivity check
  # Strip protocol
  hostport="${PROXY_URL##*://}"
  # Strip path
  hostport="${hostport%%/*}"
  # Strip auth (user:pass@)
  hostport="${hostport##*@}"
  # Split host and port
  host="${hostport%%:*}"
  port="${hostport##*:}"

  # Default port based on protocol
  if [[ "$host" == "$port" ]]; then
    case "$PROXY_URL" in
      socks5://*|socks5h://*) port=1080 ;;
      socks4://*) port=1080 ;;
      https://*) port=443 ;;
      *) port=8080 ;;
    esac
  fi

  # Check if proxy is reachable (2s timeout)
  if timeout 2 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
    export HTTPS_PROXY="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export ALL_PROXY="$PROXY_URL"

    # For SOCKS proxies, also set up git ssh proxy
    case "$PROXY_URL" in
      socks5://*|socks5h://*|socks4://*)
        if command -v nc &>/dev/null; then
          export GIT_SSH_COMMAND="ssh -o ProxyCommand='nc -X 5 -x ${host}:${port} %h %p'"
        elif command -v socat &>/dev/null; then
          export GIT_SSH_COMMAND="ssh -o ProxyCommand='socat - SOCKS5:${host}:%h:%p,socksport=${port}'"
        fi
        ;;
    esac

    echo "[proxy] Using $PROXY_URL" >&2
  else
    echo "[proxy] Error: proxy $PROXY_URL is not reachable (${host}:${port})" >&2
    exit 1
  fi
fi

# --- Set resilience env vars --------------------------------------------------

export CLAUDE_STREAM_IDLE_TIMEOUT_MS="${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-999999999}"

# --- Find and exec the real claude binary -------------------------------------

SELF="$(readlink -f "$0")"

find_real_claude() {
  local IFS=':'
  for dir in $PATH; do
    local candidate="$dir/claude"
    if [[ -x "$candidate" ]]; then
      local resolved
      resolved="$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
      if [[ "$resolved" != "$SELF" ]]; then
        echo "$candidate"
        return 0
      fi
    fi
  done

  # Try npx as fallback
  if command -v npx &>/dev/null; then
    echo "npx"
    return 0
  fi

  return 1
}

CLAUDE_BIN="$(find_real_claude)" || {
  echo "[proxy] Error: could not find claude binary in PATH" >&2
  exit 1
}

if [[ "$CLAUDE_BIN" == "npx" ]]; then
  exec npx @anthropic-ai/claude-code "$@"
else
  exec "$CLAUDE_BIN" "$@"
fi
