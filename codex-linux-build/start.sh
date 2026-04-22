#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
WEBVIEW_PORT="${CODEX_WEBVIEW_PORT:-5175}"
APP_DESKTOP_ID="codex-desktop"

log() {
    printf '[codex-linux] %s\n' "$1"
}

err() {
    printf '[codex-linux] %s\n' "$1" >&2
}

find_electron_bin() {
    local candidate=""
    local electron_cli="$SCRIPT_DIR/node_modules/electron/cli.js"
    local electron_dist="$SCRIPT_DIR/node_modules/electron/dist/electron"

    if [ -n "${ELECTRON_BIN:-}" ] && [ -x "${ELECTRON_BIN}" ]; then
        printf '%s\n' "${ELECTRON_BIN}"
        return 0
    fi

    if [ -x "$electron_dist" ]; then
        printf '%s\n' "$electron_dist"
        return 0
    fi

    if [ -f "$electron_cli" ]; then
        printf 'node:%s\n' "$electron_cli"
        return 0
    fi

    candidate="$(find "$SCRIPT_DIR/node_modules" -path '*/electron/dist/electron' -type f 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if command -v electron >/dev/null 2>&1; then
        command -v electron
        return 0
    fi

    return 1
}

find_node_bin() {
    local candidate=""

    candidate="$(find "$SCRIPT_DIR/node_modules" -path '*/electron/dist/electron' -type f 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi

    return 1
}

free_webview_port() {
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${WEBVIEW_PORT}/tcp" >/dev/null 2>&1 || true
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -ti :"${WEBVIEW_PORT}" | xargs -r kill >/dev/null 2>&1 || true
    fi
}

resolve_codex_cli() {
    local local_codex="$SCRIPT_DIR/node_modules/.bin/codex"
    local packaged_codex_js="$SCRIPT_DIR/node_modules/@openai/codex/bin/codex.js"

    if [ -x "$local_codex" ]; then
        printf '%s\n' "$local_codex"
        return 0
    fi

    if [ -f "$packaged_codex_js" ]; then
        printf '%s\n' "$packaged_codex_js"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    return 1
}

if [ ! -d "$DIST_DIR" ]; then
    err "Build output not found at $DIST_DIR. Run ./build.sh first."
    exit 1
fi

if [ ! -f "$DIST_DIR/webview-server.js" ]; then
    err "Missing $DIST_DIR/webview-server.js. Re-run ./build.sh."
    exit 1
fi

ELECTRON_BIN_RESOLVED="$(find_electron_bin || true)"
if [ -z "$ELECTRON_BIN_RESOLVED" ]; then
    err "Electron runtime not found. Run 'pnpm install' in $SCRIPT_DIR."
    exit 1
fi

NODE_BIN_RESOLVED="$(find_node_bin || true)"
if [ -z "$NODE_BIN_RESOLVED" ]; then
    err "Node runtime not found. Install dependencies with bundled Electron runtime or provide node in PATH."
    exit 1
fi

if CODEX_CLI_PATH_RESOLVED="$(resolve_codex_cli || true)"; then
    export CODEX_CLI_PATH="$CODEX_CLI_PATH_RESOLVED"
    log "Using Codex CLI at $CODEX_CLI_PATH"
else
    err "Codex CLI not found. Install dependencies with 'pnpm install' or provide CODEX_CLI_PATH."
    exit 1
fi

free_webview_port
if [[ "$NODE_BIN_RESOLVED" == *"/electron/dist/electron" ]]; then
    ELECTRON_RUN_AS_NODE=1 "$NODE_BIN_RESOLVED" "$DIST_DIR/webview-server.js" &
else
    "$NODE_BIN_RESOLVED" "$DIST_DIR/webview-server.js" &
fi
WEBVIEW_PID=$!

cleanup() {
    kill "$WEBVIEW_PID" >/dev/null 2>&1 || true
    wait "$WEBVIEW_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.3

OZONE_FLAGS=()
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    OZONE_FLAGS=(--enable-features=UseOzonePlatform --ozone-platform=wayland)
fi

export CHROME_DESKTOP="${APP_DESKTOP_ID}.desktop"

if [[ "$ELECTRON_BIN_RESOLVED" == node:* ]]; then
    exec node "${ELECTRON_BIN_RESOLVED#node:}" \
        "$DIST_DIR" \
        --no-sandbox \
        --disable-gpu-compositing \
        --disable-background-timer-throttling \
        --class="$APP_DESKTOP_ID" \
        "${OZONE_FLAGS[@]}" \
        "$@"
fi

exec "$ELECTRON_BIN_RESOLVED" \
    "$DIST_DIR" \
    --no-sandbox \
    --disable-gpu-compositing \
    --disable-background-timer-throttling \
    --class="$APP_DESKTOP_ID" \
    "${OZONE_FLAGS[@]}" \
    "$@"
