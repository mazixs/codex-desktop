#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
ELECTRON_DIST_DIR="$SCRIPT_DIR/node_modules/electron/dist"
PRODUCT_RESOURCES_DIR="$ELECTRON_DIST_DIR/resources"
PRODUCT_APP_ASAR="$PRODUCT_RESOURCES_DIR/app.asar"
PRODUCT_ELECTRON_BIN="$ELECTRON_DIST_DIR/codex-desktop"
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
    local electron_dist="$ELECTRON_DIST_DIR/electron"

    if [ -n "${ELECTRON_BIN:-}" ] && [ -x "${ELECTRON_BIN}" ]; then
        printf '%s\n' "${ELECTRON_BIN}"
        return 0
    fi

    if [ -f "$PRODUCT_APP_ASAR" ] && [ -x "$PRODUCT_ELECTRON_BIN" ]; then
        printf '%s\n' "$PRODUCT_ELECTRON_BIN"
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
    local electron_dist="$ELECTRON_DIST_DIR/electron"

    if [ -x "$PRODUCT_ELECTRON_BIN" ]; then
        printf '%s\n' "$PRODUCT_ELECTRON_BIN"
        return 0
    fi

    if [ -x "$electron_dist" ]; then
        printf '%s\n' "$electron_dist"
        return 0
    fi

    candidate="$(find "$SCRIPT_DIR/node_modules" \( -path '*/electron/dist/codex-desktop' -o -path '*/electron/dist/electron' \) \( -type f -o -type l \) 2>/dev/null | head -n 1 || true)"
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

ensure_electron_binary() {
    local electron_dir="$SCRIPT_DIR/node_modules/electron"
    local electron_dist="$electron_dir/dist/electron"
    local product_dist="$electron_dir/dist/codex-desktop"
    local path_txt="$electron_dir/path.txt"

    if [ -d "$electron_dir" ] && { { [ ! -x "$electron_dist" ] && [ ! -x "$product_dist" ]; } || [ ! -f "$path_txt" ]; }; then
        log "Electron binary is missing or incomplete. Triggering robust extraction..."
        (
            cd "$SCRIPT_DIR"
            node -e '
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const electronDir = path.resolve("node_modules/electron");
const packageJson = require(path.join(electronDir, "package.json"));
const version = packageJson.version;
const platform = "linux";
const arch = "x64";

console.log("Resolving Electron binary v" + version + "...");
const { downloadArtifact } = require("@electron/get");
downloadArtifact({
  version,
  artifactName: "electron",
  platform,
  arch
})
  .then((zipPath) => {
    console.log("Downloaded zip to:", zipPath);
    const distDir = path.join(electronDir, "dist");
    fs.mkdirSync(distDir, { recursive: true });

    const unzipRes = spawnSync("unzip", ["-o", "-d", distDir, zipPath]);
    if (unzipRes.status === 0) {
      console.log("Successfully extracted using unzip!");
    } else {
      console.log("unzip utility failed or not found. Falling back to extract-zip...");
      const extract = require("extract-zip");
      return extract(zipPath, { dir: distDir });
    }
  })
  .then(() => {
    const distPath = path.join(electronDir, "dist");
    const srcTypeDefPath = path.join(distPath, "electron.d.ts");
    const targetTypeDefPath = path.join(electronDir, "electron.d.ts");
    if (fs.existsSync(srcTypeDefPath)) {
      fs.renameSync(srcTypeDefPath, targetTypeDefPath);
    }
    fs.writeFileSync(path.join(electronDir, "path.txt"), "electron");
    console.log("Electron binary installation completed successfully!");
  })
  .catch((err) => {
    console.error("Error installing Electron binary:", err.stack);
    process.exit(1);
  });
'
        )
    fi
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

PRODUCT_MODE=0
if [ -f "$PRODUCT_APP_ASAR" ]; then
    PRODUCT_MODE=1
fi

if [ "$PRODUCT_MODE" -eq 0 ]; then
    if [ ! -d "$DIST_DIR" ]; then
        err "Build output not found at $DIST_DIR. Run ./build.sh first."
        exit 1
    fi

    if [ ! -f "$DIST_DIR/webview-server.js" ]; then
        err "Missing $DIST_DIR/webview-server.js. Re-run ./build.sh."
        exit 1
    fi
fi

ensure_electron_binary

if [ "$PRODUCT_MODE" -eq 1 ] && [ ! -x "$PRODUCT_ELECTRON_BIN" ]; then
    err "Product Electron binary not found at $PRODUCT_ELECTRON_BIN. Re-run ./build.sh --package."
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

resolve_current_app_version() {
    local node_path="$1"
    local metadata_path="$SCRIPT_DIR/build-metadata.env"
    local version=""

    if [ "$PRODUCT_MODE" -eq 1 ] && [ -f "$metadata_path" ]; then
        version="$(sed -n 's/^UPSTREAM_VERSION=//p' "$metadata_path" | head -n 1)"
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    if [ -f "$DIST_DIR/package.json" ] && [ -x "$node_path" ]; then
        if [[ "$node_path" == *"/electron/dist/"* ]]; then
            ELECTRON_RUN_AS_NODE=1 "$node_path" -e 'console.log(require(process.argv[1]).version)' "$DIST_DIR/package.json" 2>/dev/null || true
        else
            "$node_path" -e 'console.log(require(process.argv[1]).version)' "$DIST_DIR/package.json" 2>/dev/null || true
        fi
    fi
}

clean_stale_plugins_cache() {
    local version_file="${HOME:-}/.codex/.last-run-version"
    local current_version=""
    local node_path="$1"

    current_version="$(resolve_current_app_version "$node_path")"

    if [ -n "$current_version" ]; then
        local last_version=""
        [ -f "$version_file" ] && last_version="$(cat "$version_file" 2>/dev/null || true)"
        
        if [ "$current_version" != "$last_version" ]; then
            log "Version changed from '$last_version' to '$current_version'. Cleaning stale plugins cache..."
            rm -rf "${HOME:-}/.codex/plugins/cache/openai-bundled"
            rm -rf "${HOME:-}/.codex/plugins/cache/openai-bundled-dev"
            rm -rf "${HOME:-}/.codex/.tmp/bundled-marketplaces"
            mkdir -p "$(dirname "$version_file")"
            echo "$current_version" > "$version_file"
        fi
    fi
}
clean_stale_plugins_cache "$NODE_BIN_RESOLVED"

if CODEX_CLI_PATH_RESOLVED="$(resolve_codex_cli || true)"; then
    export CODEX_CLI_PATH="$CODEX_CLI_PATH_RESOLVED"
    log "Using Codex CLI at $CODEX_CLI_PATH"
else
    err "Codex CLI not found. Install dependencies with 'pnpm install' or provide CODEX_CLI_PATH."
    exit 1
fi

WEBVIEW_PID=""
if [ "$PRODUCT_MODE" -eq 0 ]; then
    free_webview_port
    if [[ "$NODE_BIN_RESOLVED" == *"/electron/dist/"* ]]; then
        ELECTRON_RUN_AS_NODE=1 "$NODE_BIN_RESOLVED" "$DIST_DIR/webview-server.js" &
    else
        "$NODE_BIN_RESOLVED" "$DIST_DIR/webview-server.js" &
    fi
    WEBVIEW_PID=$!
fi

cleanup() {
    if [ -n "$WEBVIEW_PID" ]; then
        kill "$WEBVIEW_PID" >/dev/null 2>&1 || true
        wait "$WEBVIEW_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [ "$PRODUCT_MODE" -eq 0 ]; then
    sleep 0.3
fi

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
    local runtime_resources_dir="$DIST_DIR"
    local runtime_node_path="$SCRIPT_DIR/dist/node"
    local runtime_node_repl_path="$SCRIPT_DIR/dist/node_repl"
    local respect_runtime_env="${CODEX_DESKTOP_RESPECT_RUNTIME_ENV:-0}"

    if [ "$PRODUCT_MODE" -eq 1 ]; then
        runtime_resources_dir="$PRODUCT_RESOURCES_DIR"
        runtime_node_path="$PRODUCT_RESOURCES_DIR/node"
        runtime_node_repl_path="$PRODUCT_RESOURCES_DIR/node_repl"
    fi

    if [ "$respect_runtime_env" != "1" ]; then
        export CODEX_ELECTRON_RESOURCES_PATH="$runtime_resources_dir"
        export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH="${CODEX_ELECTRON_RESOURCES_PATH}"
        if [ -x "$runtime_node_path" ]; then
            export CODEX_BROWSER_USE_NODE_PATH="$runtime_node_path"
        elif command -v node >/dev/null 2>&1; then
            CODEX_BROWSER_USE_NODE_PATH="$(command -v node)"
            export CODEX_BROWSER_USE_NODE_PATH
        fi
        if [ -n "${CODEX_BROWSER_USE_NODE_PATH:-}" ]; then
            export NODE_REPL_NODE_PATH="$CODEX_BROWSER_USE_NODE_PATH"
        fi
        if [ -x "$runtime_node_repl_path" ]; then
            export CODEX_NODE_REPL_PATH="$runtime_node_repl_path"
        elif command -v node_repl >/dev/null 2>&1; then
            CODEX_NODE_REPL_PATH="$(command -v node_repl)"
            export CODEX_NODE_REPL_PATH
        fi
    else
        if [ -z "${CODEX_ELECTRON_RESOURCES_PATH:-}" ]; then
            export CODEX_ELECTRON_RESOURCES_PATH="$runtime_resources_dir"
        fi
        if [ -z "${CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH:-}" ]; then
            export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH="${CODEX_ELECTRON_RESOURCES_PATH}"
        fi
        if [ -z "${CODEX_BROWSER_USE_NODE_PATH:-}" ]; then
            if [ -x "$runtime_node_path" ]; then
                export CODEX_BROWSER_USE_NODE_PATH="$runtime_node_path"
            elif command -v node >/dev/null 2>&1; then
                CODEX_BROWSER_USE_NODE_PATH="$(command -v node)"
                export CODEX_BROWSER_USE_NODE_PATH
            fi
        fi
        if [ -n "${CODEX_BROWSER_USE_NODE_PATH:-}" ] && [ -z "${NODE_REPL_NODE_PATH:-}" ]; then
            export NODE_REPL_NODE_PATH="$CODEX_BROWSER_USE_NODE_PATH"
        fi
        if [ -z "${CODEX_NODE_REPL_PATH:-}" ]; then
            if [ -x "$runtime_node_repl_path" ]; then
                export CODEX_NODE_REPL_PATH="$runtime_node_repl_path"
            elif command -v node_repl >/dev/null 2>&1; then
                CODEX_NODE_REPL_PATH="$(command -v node_repl)"
                export CODEX_NODE_REPL_PATH
            fi
        fi
    fi
    # Ensure node_repl is discoverable via PATH for Codex CLI MCP server lookup
    if [ -x "$runtime_node_repl_path" ]; then
        local runtime_bin_dir
        runtime_bin_dir="$(dirname "$runtime_node_repl_path")"
        case ":${PATH}:" in
            *":$runtime_bin_dir:") ;;
            *) export PATH="$runtime_bin_dir:$PATH" ;;
        esac
    fi

    # Auto-register node_repl MCP server if codex CLI is available and server not yet added
    if command -v codex >/dev/null 2>&1 && [ -x "$runtime_node_repl_path" ]; then
        if ! codex mcp list 2>/dev/null | grep -q "^node_repl[[:space:]]"; then
            codex mcp add node_repl "$runtime_node_repl_path" >/dev/null 2>&1 || true
        fi
    fi
}

resolve_ozone_platform_args "$@"
resolve_browser_use_runtime_env

export CHROME_DESKTOP="${APP_DESKTOP_ID}.desktop"
register_url_scheme_handlers

if [ "$PRODUCT_MODE" -eq 1 ]; then
    "$ELECTRON_BIN_RESOLVED" \
        --no-sandbox \
        --disable-gpu-compositing \
        --disable-background-timer-throttling \
        --class="$APP_DESKTOP_ID" \
        "${OZONE_FLAGS[@]}" \
        "$@"
elif [[ "$ELECTRON_BIN_RESOLVED" == node:* ]]; then
    node "${ELECTRON_BIN_RESOLVED#node:}" \
        "$DIST_DIR" \
        --no-sandbox \
        --disable-gpu-compositing \
        --disable-background-timer-throttling \
        --class="$APP_DESKTOP_ID" \
        "${OZONE_FLAGS[@]}" \
        "$@"
else
    "$ELECTRON_BIN_RESOLVED" \
        "$DIST_DIR" \
        --no-sandbox \
        --disable-gpu-compositing \
        --disable-background-timer-throttling \
        --class="$APP_DESKTOP_ID" \
        "${OZONE_FLAGS[@]}" \
        "$@"
fi
