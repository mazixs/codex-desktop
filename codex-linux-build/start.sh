#!/usr/bin/env bash
# Codex Desktop for Linux — Launch Script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
ELECTRON_BIN="/home/mazix/Documents/GitHub/codex-desktop/codex-linux-build/node_modules/.pnpm/electron@40.0.0/node_modules/electron/dist/electron"
WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5175}

# Start webview static server in background
# First ensure the port is free
fuser -k $WEBVIEW_PORT/tcp 2>/dev/null || true
node "$DIST_DIR/webview-server.js" &
WEBVIEW_PID=$!

# Give server time to start
sleep 0.3

cleanup() {
    kill $WEBVIEW_PID 2>/dev/null || true
    wait $WEBVIEW_PID 2>/dev/null || true
}
trap cleanup EXIT

# Detect session type
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    OZONE_FLAGS="--enable-features=UseOzonePlatform --ozone-platform=wayland"
else
    OZONE_FLAGS=""
fi

# Codex CLI path — use local node_modules or system
LOCAL_CODEX="$SCRIPT_DIR/node_modules/.bin/codex"
if [ -f "$LOCAL_CODEX" ]; then
    export CODEX_CLI_PATH="$LOCAL_CODEX"
    echo "[INFO] Using local Codex CLI: $LOCAL_CODEX"
else
    CODEX_CLI=$(command -v codex 2>/dev/null || echo "")
    if [ -z "$CODEX_CLI" ]; then
        echo "[WARN] Codex CLI not found. Install with: npm i @openai/codex"
    else
        export CODEX_CLI_PATH="$CODEX_CLI"
    fi
fi

# Launch Electron
exec "$ELECTRON_BIN" \
    "$DIST_DIR" \
    --no-sandbox \
    --disable-gpu-compositing \
    --disable-background-timer-throttling \
    $OZONE_FLAGS \
    "$@"
