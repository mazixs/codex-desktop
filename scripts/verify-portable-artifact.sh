#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=./ci-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ci-lib.sh"

ARTIFACTS_DIR="$PROJECT_ROOT/codex-linux-build/artifacts"
RELEASE_NOTES_PATH=""
WORK_DIR=""

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-portable-artifact.sh [--artifacts-dir <dir>] [--release-notes <path>]

Options:
  --artifacts-dir DIR   Directory containing the portable artifact and metadata
  --release-notes PATH  Optional release notes file to validate
  --help                Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --artifacts-dir)
                ARTIFACTS_DIR="${2:-}"
                shift 2
                ;;
            --release-notes)
                RELEASE_NOTES_PATH="${2:-}"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                ci_fail "Unknown option: $1"
                ;;
        esac
    done
}

main() {
    local archive_path=""
    local archive_size=0
    local extract_root=""
    local main_entry_path=""
    local electron_bin=""
    local resources_dir=""
    local size=""
    local launch_log=""
    local launch_rc=0

    parse_args "$@"

    for cmd in node tar timeout xvfb-run grep stat mktemp file; do
        require_command "$cmd"
    done

    require_dir "$ARTIFACTS_DIR"
    archive_path="$(find_single_matching_file "$ARTIFACTS_DIR" "$(portable_release_glob)" "portable archive")"
    require_file "$ARTIFACTS_DIR/build-metadata.env"
    require_file "${archive_path}.sha256"

    archive_size="$(stat -c%s "$archive_path")"
    if [ "$archive_size" -lt "$PORTABLE_MIN_SIZE_BYTES" ]; then
        ci_fail "Portable archive is only $((archive_size / 1048576)) MB — Electron runtime is likely missing"
    fi

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-portable-check.XXXXXX")"
    tar -xzf "$archive_path" -C "$WORK_DIR"
    extract_root="$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$extract_root" ]; then
        ci_fail "Portable archive did not extract into a top-level directory"
    fi

    require_file "$extract_root/build-metadata.env"
    require_file "$extract_root/start.sh"
    require_file "$extract_root/node_modules/electron/dist/electron"
    require_file "$extract_root/node_modules/electron/dist/codex-desktop"
    resources_dir="$extract_root/node_modules/electron/dist/resources"
    electron_bin="$extract_root/node_modules/electron/dist/codex-desktop"
    require_file "$resources_dir/app.asar"
    require_dir "$resources_dir/app.asar.unpacked"
    require_dir "$resources_dir/plugins/openai-bundled"
    require_file "$resources_dir/plugins/openai-bundled/.agents/plugins/marketplace.json"
    require_file "$resources_dir/node"
    require_file "$resources_dir/node.sha256"
    require_file "$resources_dir/node_repl"
    require_file "$resources_dir/node_repl.sha256"
    require_file "$resources_dir/node_repl.runtime.env"
    assert_file_contains "$resources_dir/node_repl.runtime.env" '^NODE_REPL_RUNTIME_VERSION=' "node_repl runtime metadata is missing the source version"
    assert_file_contains "$resources_dir/node_repl.runtime.env" '^NODE_REPL_RUNTIME_SOURCE_SHA256=' "node_repl runtime metadata is missing the source checksum"
    (
        cd "$resources_dir"
        sha256sum -c node.sha256
        sha256sum -c node_repl.sha256
    )
    file "$resources_dir/node_repl" | grep -q "ELF" || ci_fail "Product node_repl is not a Linux ELF binary"
    require_file "$resources_dir/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    require_file "$resources_dir/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
    assert_file_contains "$extract_root/start.sh" "register_url_scheme_handlers" "Portable launcher is missing URL scheme registration"
    assert_file_contains "$extract_root/start.sh" "xdg-mime default" "Portable launcher is missing xdg-mime URL scheme registration"
    assert_file_contains "$extract_root/start.sh" "PRODUCT_APP_ASAR" "Portable launcher is missing product app.asar mode"

    main_entry_path="$(
        ELECTRON_RUN_AS_NODE=1 "$electron_bin" - "$resources_dir/app.asar" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const appAsar = process.argv[2];
const manifestPath = path.join(appAsar, "package.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (!manifest.main) process.exit(1);
const mainEntry = path.join(appAsar, manifest.main);
if (!fs.existsSync(mainEntry)) process.exit(2);
process.stdout.write(mainEntry);
NODE
    )"
    [ -n "$main_entry_path" ] || ci_fail "Unable to resolve product app main entry from app.asar"

    for size in 16 24 32 48 64 128 256 512; do
        require_file "$ARTIFACTS_DIR/icons/hicolor/${size}x${size}/apps/codex-desktop.png"
        require_file "$extract_root/icons/hicolor/${size}x${size}/apps/codex-desktop.png"
    done

    ELECTRON_RUN_AS_NODE=1 "$electron_bin" --check "$main_entry_path"

    mkdir -p "$WORK_DIR/home"
    launch_log="$WORK_DIR/portable-launch.log"
    env \
        CODEX_BROWSER_USE_NODE_PATH=/usr/bin/node \
        CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH=/opt/codex-desktop/dist \
        CODEX_ELECTRON_RESOURCES_PATH=/opt/codex-desktop/dist \
        CODEX_NODE_REPL_PATH=/opt/codex-desktop/dist/node_repl \
        NODE_REPL_NODE_PATH=/usr/bin/node \
        HOME="$WORK_DIR/home" \
        XDG_SESSION_TYPE=x11 \
        WAYLAND_DISPLAY='' \
        timeout 25s xvfb-run -a "$extract_root/start.sh" >"$launch_log" 2>&1 || launch_rc=$?
    if [ "$launch_rc" -ne 0 ] && [ "$launch_rc" -ne 124 ]; then
        cat "$launch_log"
        ci_fail "Portable launcher exited with status $launch_rc"
    fi

    if grep -Eq 'Electron runtime not found|Build output not found|Codex CLI not found|Product Electron binary not found|Desktop bootstrap failed' "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher reported a fatal bootstrap error"
    fi
    if grep -Eq 'packaged[":= ]+false|react devtools extension loaded' "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher used unpacked/dev Electron runtime"
    fi
    if ! grep -Eq 'packaged[":= ]+true' "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher did not report packaged:true"
    fi
    if grep -Fq '/opt/codex-desktop/dist/node_repl' "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher leaked stale inherited CODEX_NODE_REPL_PATH into Browser Use runtime"
    fi
    if ! grep -Fq "$resources_dir/node_repl" "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher did not expose product node_repl to Browser Use runtime"
    fi

    if [ -n "$RELEASE_NOTES_PATH" ]; then
        require_file "$RELEASE_NOTES_PATH"
        assert_file_contains "$RELEASE_NOTES_PATH" 'Arch Linux installer' "Release notes are missing the Arch Linux installer section"
        assert_file_contains "$RELEASE_NOTES_PATH" 'Portable Linux archive' "Release notes are missing the Portable Linux archive section"
    fi

    ci_log "Portable artifact contract verified: $archive_path"
}

main "$@"
