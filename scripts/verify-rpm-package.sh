#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-lib.sh
source "$SCRIPT_DIR/ci-lib.sh"

PACKAGE_FILE=""
LAUNCHER="${LAUNCHER:-codex-desktop}"

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-rpm-package.sh --package <file.rpm> [--launcher <cmd>]

Options:
  --package FILE      RPM package file to validate and install
  --launcher CMD      Launcher command to execute after installation (default: codex-desktop)
  --help              Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --package)
                PACKAGE_FILE="${2:-}"
                shift 2
                ;;
            --launcher)
                LAUNCHER="${2:-}"
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

assert_package_entry() {
    local listing_file="$1"
    local entry="$2"

    if ! grep -Fxq "$entry" "$listing_file"; then
        ci_fail "RPM package is missing required entry: $entry"
    fi
}

assert_desktop_entry_contract() {
    local extract_dir=""
    local desktop_file=""

    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-rpm-package-desktop.XXXXXX")"
    (
        cd "$extract_dir"
        rpm2cpio "$PACKAGE_FILE" | cpio -idm --quiet "*codex-desktop.desktop"
    )
    # cpio restores relative to current dir, so find it recursively
    desktop_file="$(find "$extract_dir" -name "codex-desktop.desktop" | head -n 1)"

    if [ -z "$desktop_file" ] || [ ! -f "$desktop_file" ]; then
        ci_fail "Could not extract desktop entry from RPM package"
    fi

    assert_file_contains "$desktop_file" "Exec=codex-desktop %u" "RPM desktop entry does not accept URL arguments"
    assert_file_contains "$desktop_file" "MimeType=x-scheme-handler/codex;x-scheme-handler/codex-browser-sidebar;" "RPM desktop entry does not register Codex URL schemes"

    rm -rf "$extract_dir"
}

install_package() {
    if [ "${EUID}" -eq 0 ]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "$PACKAGE_FILE"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$PACKAGE_FILE"
        else
            rpm -ivh "$PACKAGE_FILE"
        fi
        return
    fi

    require_command sudo
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$PACKAGE_FILE"
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y "$PACKAGE_FILE"
    else
        sudo rpm -ivh "$PACKAGE_FILE"
    fi
}

run_smoke_test() {
    local smoke_log="/tmp/codex-desktop-smoke.log"
    local launch_rc=0

    mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/.local/share"
    timeout 25s xvfb-run -a "$LAUNCHER" >"$smoke_log" 2>&1 || launch_rc=$?
    if [ "$launch_rc" -ne 0 ] && [ "$launch_rc" -ne 124 ]; then
        cat "$smoke_log"
        exit 1
    fi

    if grep -Eq "Electron runtime not found|Build output not found|Codex CLI not found" "$smoke_log"; then
        cat "$smoke_log"
        exit 1
    fi
}

main() {
    local listing_file=""

    parse_args "$@"

    for cmd in rpm rpm2cpio cpio grep timeout xvfb-run; do
        require_command "$cmd"
    done

    if [ -z "$PACKAGE_FILE" ]; then
        usage >&2
        exit 1
    fi

    require_file "$PACKAGE_FILE"
    listing_file="$(mktemp "${TMPDIR:-/tmp}/codex-rpm-package-list.XXXXXX")"
    
    # rpm -qpl list files in rpm, starting with /
    rpm -qpl "$PACKAGE_FILE" >"$listing_file"

    assert_package_entry "$listing_file" "/opt/codex-desktop/start.sh"
    assert_package_entry "$listing_file" "/usr/bin/codex-desktop"
    assert_package_entry "$listing_file" "/usr/share/applications/codex-desktop.desktop"
    assert_package_entry "$listing_file" "/usr/share/pixmaps/codex-desktop.png"
    assert_package_entry "$listing_file" "/opt/codex-desktop/node_modules/electron/dist/electron"
    assert_package_entry "$listing_file" "/opt/codex-desktop/dist/.vite/build/bootstrap.js"
    assert_desktop_entry_contract

    install_package
    run_smoke_test

    rm -f "$listing_file"
    ci_log "RPM package contract verified: $PACKAGE_FILE"
}

main "$@"
