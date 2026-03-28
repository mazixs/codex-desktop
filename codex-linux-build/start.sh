#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
WEBVIEW_PORT="${CODEX_WEBVIEW_PORT:-5175}"
APP_DESKTOP_ID="codex-desktop"
UPDATE_CHECK_SCRIPT="$SCRIPT_DIR/update-check.sh"

log() {
    printf '[codex-linux] %s\n' "$1"
}

err() {
    printf '[codex-linux] %s\n' "$1" >&2
}

warn() {
    printf '[codex-linux] %s\n' "$1" >&2
}

# ---- Pre-launch update check ----
# Set CODEX_SKIP_UPDATE_CHECK=1 to disable
if [ "${CODEX_SKIP_UPDATE_CHECK:-0}" != "1" ] && [ -x "$UPDATE_CHECK_SCRIPT" ]; then
    _SOURCED_BY_START_SH=1
    source "$UPDATE_CHECK_SCRIPT"
    update_info="$(check_update)" && {
        resolved_url="$(printf '%s' "$update_info" | sed -n '1p')"
        log "Upstream update detected — rebuilding..."
        if "$SCRIPT_DIR/build.sh" --clean; then
            # Write metadata after successful build
            etag="$(printf '%s' "$update_info" | sed -n '2p')"
            last_modified="$(printf '%s' "$update_info" | sed -n '3p')"
            write_metadata "$resolved_url" "$etag" "$last_modified" "$LINUX_PATCH_VERSION"
            log "Update applied successfully"
        else
            warn "Auto-rebuild failed — launching existing version"
        fi
    } || true
fi

find_electron_bin() {
    local candidate=""

    if [ -n "${ELECTRON_BIN:-}" ] && [ -x "${ELECTRON_BIN}" ]; then
        printf '%s\n' "${ELECTRON_BIN}"
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

    if [ -x "$local_codex" ]; then
        printf '%s\n' "$local_codex"
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

if CODEX_CLI_PATH_RESOLVED="$(resolve_codex_cli || true)"; then
    export CODEX_CLI_PATH="$CODEX_CLI_PATH_RESOLVED"
    log "Using Codex CLI at $CODEX_CLI_PATH"
else
    err "Codex CLI not found. Install dependencies with 'pnpm install' or provide CODEX_CLI_PATH."
    exit 1
fi

free_webview_port
node "$DIST_DIR/webview-server.js" &
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
export ELECTRON_FORCE_IS_PACKAGED=true
export ELECTRON_IS_DEV=0
export BUILD_FLAVOR=prod

exec "$ELECTRON_BIN_RESOLVED" \
    "$DIST_DIR" \
    --no-sandbox \
    --disable-gpu-compositing \
    --disable-background-timer-throttling \
    --class="$APP_DESKTOP_ID" \
    "${OZONE_FLAGS[@]}" \
    "$@"
