#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=./ci-lib.sh
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
    local size=""
    local launch_log=""
    local launch_rc=0

    parse_args "$@"

    for cmd in node tar timeout xvfb-run grep stat mktemp; do
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

    require_dir "$extract_root/dist"
    require_file "$extract_root/dist/webview-server.js"
    require_file "$extract_root/dist/.vite/build/main.js"
    require_file "$extract_root/build-metadata.env"
    require_file "$extract_root/start.sh"
    require_file "$extract_root/node_modules/electron/dist/electron"
    require_file "$extract_root/dist/skills/.curated/playwright/SKILL.md"

    for size in 16 24 32 48 64 128 256 512; do
        require_file "$ARTIFACTS_DIR/icons/hicolor/${size}x${size}/apps/codex-desktop.png"
        require_file "$extract_root/icons/hicolor/${size}x${size}/apps/codex-desktop.png"
    done

    node --check "$extract_root/dist/.vite/build/main.js"

    mkdir -p "$WORK_DIR/home"
    launch_log="$WORK_DIR/portable-launch.log"
    HOME="$WORK_DIR/home" timeout 25s xvfb-run -a "$extract_root/start.sh" >"$launch_log" 2>&1 || launch_rc=$?
    if [ "$launch_rc" -ne 0 ] && [ "$launch_rc" -ne 124 ]; then
        cat "$launch_log"
        ci_fail "Portable launcher exited with status $launch_rc"
    fi

    if grep -Eq 'Electron runtime not found|Build output not found|Codex CLI not found' "$launch_log"; then
        cat "$launch_log"
        ci_fail "Portable launcher reported a fatal bootstrap error"
    fi

    if [ -n "$RELEASE_NOTES_PATH" ]; then
        require_file "$RELEASE_NOTES_PATH"
        assert_file_contains "$RELEASE_NOTES_PATH" 'Arch Linux installer' "Release notes are missing the Arch Linux installer section"
        assert_file_contains "$RELEASE_NOTES_PATH" 'Portable Linux archive' "Release notes are missing the Portable Linux archive section"
    fi

    ci_log "Portable artifact contract verified: $archive_path"
}

main "$@"
