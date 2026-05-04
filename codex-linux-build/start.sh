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

desktop_entry_exists() {
    local desktop_name="${APP_DESKTOP_ID}.desktop"
    local data_home="${XDG_DATA_HOME:-${HOME:-}/.local/share}"
    local data_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    local data_dir=""
    local -a data_dirs_array=()

    [ -f "$data_home/applications/$desktop_name" ] && return 0

    IFS=: read -r -a data_dirs_array <<< "$data_dirs"
    for data_dir in "${data_dirs_array[@]}"; do
        [ -f "$data_dir/applications/$desktop_name" ] && return 0
    done

    return 1
}

register_url_scheme_handlers() {
    local desktop_name="${APP_DESKTOP_ID}.desktop"
    local scheme=""
    local mime_type=""
    local current_handler=""

    command -v xdg-mime >/dev/null 2>&1 || return 0
    desktop_entry_exists || return 0

    for scheme in codex codex-browser-sidebar; do
        mime_type="x-scheme-handler/$scheme"
        current_handler="$(xdg-mime query default "$mime_type" 2>/dev/null || true)"
        [ "$current_handler" = "$desktop_name" ] && continue
        xdg-mime default "$desktop_name" "$mime_type" >/dev/null 2>&1 || true
    done
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

has_electron_flag() {
    local flag_name="$1"
    shift
    local arg
    for arg in "$@"; do
        case "$arg" in
            "$flag_name"|"$flag_name="*) return 0 ;;
        esac
    done
    return 1
}

resolve_ozone_platform_args() {
    OZONE_FLAGS=()
    if has_electron_flag "--ozone-platform" "$@" || has_electron_flag "--ozone-platform-hint" "$@"; then
        return 0
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        OZONE_FLAGS=(--enable-features=UseOzonePlatform --ozone-platform=wayland)
    fi
}

resolve_browser_use_runtime_env() {
    if [ -z "${CODEX_ELECTRON_RESOURCES_PATH:-}" ]; then
        export CODEX_ELECTRON_RESOURCES_PATH="$SCRIPT_DIR/dist"
    fi
    if [ -z "${CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH:-}" ]; then
        export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH="${CODEX_ELECTRON_RESOURCES_PATH}"
    fi
    if [ -z "${CODEX_BROWSER_USE_NODE_PATH:-}" ]; then
        if [ -x "$SCRIPT_DIR/dist/node" ]; then
            export CODEX_BROWSER_USE_NODE_PATH="$SCRIPT_DIR/dist/node"
        elif command -v node >/dev/null 2>&1; then
            CODEX_BROWSER_USE_NODE_PATH="$(command -v node)"
            export CODEX_BROWSER_USE_NODE_PATH
        fi
    fi
    if [ -n "${CODEX_BROWSER_USE_NODE_PATH:-}" ] && [ -z "${NODE_REPL_NODE_PATH:-}" ]; then
        export NODE_REPL_NODE_PATH="$CODEX_BROWSER_USE_NODE_PATH"
    fi
    if [ -z "${CODEX_NODE_REPL_PATH:-}" ]; then
        if [ -x "$SCRIPT_DIR/dist/node_repl" ]; then
            export CODEX_NODE_REPL_PATH="$SCRIPT_DIR/dist/node_repl"
        elif command -v node_repl >/dev/null 2>&1; then
            CODEX_NODE_REPL_PATH="$(command -v node_repl)"
            export CODEX_NODE_REPL_PATH
        fi
    fi
    # Ensure node_repl is discoverable via PATH for Codex CLI MCP server lookup
    if [ -x "$SCRIPT_DIR/dist/node_repl" ]; then
        case ":${PATH}:" in
            *":$SCRIPT_DIR/dist:") ;;
            *) export PATH="$SCRIPT_DIR/dist:$PATH" ;;
        esac
    fi

    # Auto-register node_repl MCP server if codex CLI is available and server not yet added
    if command -v codex >/dev/null 2>&1 && [ -x "$SCRIPT_DIR/dist/node_repl" ]; then
        if ! codex mcp list 2>/dev/null | grep -q "^node_repl[[:space:]]"; then
            codex mcp add node_repl "$SCRIPT_DIR/dist/node_repl" >/dev/null 2>&1 || true
        fi
    fi
}

resolve_ozone_platform_args "$@"
resolve_browser_use_runtime_env

export CHROME_DESKTOP="${APP_DESKTOP_ID}.desktop"
register_url_scheme_handlers

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
