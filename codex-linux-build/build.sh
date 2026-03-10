#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXTRACTED_DIR="$PROJECT_ROOT/codex_extracted"
APP_UNPACKED="$EXTRACTED_DIR/app_unpacked"
BUILD_DIR="$SCRIPT_DIR/dist"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
NATIVE_BUILD_DIR="$SCRIPT_DIR/native-rebuild"
WEBVIEW_SERVER_TEMPLATE="$SCRIPT_DIR/webview-server.js"
DEFAULT_DMG_FILE="$PROJECT_ROOT/Codex.dmg"
DMG_FILE="$DEFAULT_DMG_FILE"
DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
ELECTRON_VERSION="${ELECTRON_VERSION:-40.0.0}"
BUILD_ARCH="${BUILD_ARCH:-x64}"
BUILD_PLATFORM="linux"
PACKAGE_RELEASE=0
INSTALL_DESKTOP_ENTRY=0
CLEAN_OUTPUTS=0
SKIP_DOWNLOAD=0
SKIP_EXTRACT=0
RELEASE_TAG="${RELEASE_TAG:-}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() {
    printf '%s[BUILD]%s %s\n' "$GREEN" "$NC" "$1"
}

warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"
}

err() {
    printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1" >&2
}

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --clean                  Remove local build outputs before building
  --package                Produce a portable .tar.gz release artifact
  --install-desktop-entry  Install/refresh the local .desktop launcher
  --skip-download          Fail instead of downloading Codex.dmg when it is absent
  --skip-extract           Fail instead of extracting app.asar when sources are absent
  --dmg PATH               Use a custom Codex.dmg path
  --help                   Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --clean)
                CLEAN_OUTPUTS=1
                ;;
            --package)
                PACKAGE_RELEASE=1
                ;;
            --install-desktop-entry)
                INSTALL_DESKTOP_ENTRY=1
                ;;
            --skip-download)
                SKIP_DOWNLOAD=1
                ;;
            --skip-extract)
                SKIP_EXTRACT=1
                ;;
            --dmg)
                shift
                if [ "$#" -eq 0 ]; then
                    err "--dmg requires a path"
                    exit 1
                fi
                DMG_FILE="$1"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

require_commands() {
    local missing=()
    local cmd

    for cmd in node npm pnpm python3 7z file tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ "$SKIP_DOWNLOAD" -eq 0 ] && [ ! -f "$DMG_FILE" ]; then
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            missing+=("curl|wget")
        fi
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi

    if [ ! -x "$SCRIPT_DIR/node_modules/.bin/electron-rebuild" ]; then
        err "Local build dependencies are missing. Run 'pnpm install' in $SCRIPT_DIR first."
        exit 1
    fi
}

clean_outputs() {
    rm -rf "$BUILD_DIR" "$ARTIFACTS_DIR" "$NATIVE_BUILD_DIR"
}

download_dmg() {
    if [ -f "$DMG_FILE" ]; then
        log "Using DMG source: $DMG_FILE"
        return 0
    fi

    if [ "$SKIP_DOWNLOAD" -eq 1 ]; then
        err "Codex.dmg not found at $DMG_FILE and --skip-download was set"
        exit 1
    fi

    mkdir -p "$(dirname "$DMG_FILE")"
    log "Downloading Codex.dmg from official source..."

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --progress-bar "$DMG_URL" -o "$DMG_FILE.tmp"
    else
        wget -q --show-progress -O "$DMG_FILE.tmp" "$DMG_URL"
    fi

    mv "$DMG_FILE.tmp" "$DMG_FILE"
}

verify_dmg() {
    local dmg_size

    dmg_size="$(stat -c%s "$DMG_FILE" 2>/dev/null || stat -f%z "$DMG_FILE" 2>/dev/null || echo 0)"
    if [ "$dmg_size" -lt 52428800 ]; then
        err "Codex.dmg is too small ($dmg_size bytes). Remove it and try again."
        exit 1
    fi
}

extract_app() {
    if [ -d "$APP_UNPACKED" ]; then
        log "Using extracted application sources from $APP_UNPACKED"
        return 0
    fi

    if [ "$SKIP_EXTRACT" -eq 1 ]; then
        err "Extracted sources not found at $APP_UNPACKED and --skip-extract was set"
        exit 1
    fi

    log "Extracting Codex.dmg..."
    rm -rf "$EXTRACTED_DIR"
    mkdir -p "$EXTRACTED_DIR"

    # 7z exits with code 2 when it skips macOS /Applications symlinks
    # inside DMGs ("Dangerous link path was ignored") — this is expected.
    local seven_z_rc=0
    7z x -y "$DMG_FILE" "-o$EXTRACTED_DIR" >/dev/null || seven_z_rc=$?
    if [ "$seven_z_rc" -ge 3 ]; then
        err "7z extraction failed with exit code $seven_z_rc"
        exit 1
    fi

    log "Extracting app.asar..."
    npx --yes asar@3.2.0 extract \
        "$EXTRACTED_DIR/Codex Installer/Codex.app/Contents/Resources/app.asar" \
        "$APP_UNPACKED"
}

copy_required_path() {
    local source_path="$1"
    local destination_dir="$2"

    if [ ! -e "$source_path" ]; then
        err "Required path missing: $source_path"
        exit 1
    fi

    cp -a "$source_path" "$destination_dir/"
}

prepare_working_copy() {
    log "Preparing working copy..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    copy_required_path "$APP_UNPACKED/.vite" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/webview" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/skills" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/package.json" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/node_modules" "$BUILD_DIR"

    if [ -d "$APP_UNPACKED/native" ]; then
        copy_required_path "$APP_UNPACKED/native" "$BUILD_DIR"
    fi

    cp "$WEBVIEW_SERVER_TEMPLATE" "$BUILD_DIR/webview-server.js"
}

rebuild_native_modules() {
    local sqlite_node=""
    local pty_node=""
    local file_type=""

    log "Rebuilding native modules for Linux..."

    rm -f "$BUILD_DIR/native/sparkle.node" 2>/dev/null || true
    mkdir -p "$BUILD_DIR/native"

    find "$BUILD_DIR/node_modules/better-sqlite3" -name '*.node' -delete 2>/dev/null || true
    find "$BUILD_DIR/node_modules/node-pty" -name '*.node' -delete 2>/dev/null || true
    rm -rf "$BUILD_DIR/node_modules/node-pty/bin" 2>/dev/null || true

    rm -rf "$NATIVE_BUILD_DIR"
    mkdir -p "$NATIVE_BUILD_DIR"

    cat > "$NATIVE_BUILD_DIR/package.json" <<'EOF'
{
  "name": "native-rebuild",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "better-sqlite3": "12.5.0",
    "node-pty": "1.1.0"
  }
}
EOF

    (
        cd "$NATIVE_BUILD_DIR"
        npm install --no-audit --no-fund --loglevel=error
        "$SCRIPT_DIR/node_modules/.bin/electron-rebuild" \
            -v "$ELECTRON_VERSION" \
            -m "$NATIVE_BUILD_DIR" \
            --types prod \
            -o better-sqlite3,node-pty
    )

    cp -a "$NATIVE_BUILD_DIR/node_modules/better-sqlite3/build" \
        "$BUILD_DIR/node_modules/better-sqlite3/"

    if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/build" ]; then
        cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/build" \
            "$BUILD_DIR/node_modules/node-pty/"
    fi

    if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/bin" ]; then
        cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/bin" \
            "$BUILD_DIR/node_modules/node-pty/"
    fi

    for runtime_dir in lib src; do
        if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/$runtime_dir" ]; then
            cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/$runtime_dir" \
                "$BUILD_DIR/node_modules/node-pty/" 2>/dev/null || true
        fi
    done

    sqlite_node="$BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    pty_node="$(find "$BUILD_DIR/node_modules/node-pty" -name '*.node' | head -n 1 || true)"

    if [ ! -f "$sqlite_node" ]; then
        err "better-sqlite3 was not rebuilt: $sqlite_node missing"
        exit 1
    fi

    file_type="$(file "$sqlite_node")"
    if ! printf '%s' "$file_type" | grep -q 'ELF'; then
        err "better-sqlite3 is not an ELF binary: $file_type"
        exit 1
    fi

    if [ -z "$pty_node" ] || [ ! -f "$pty_node" ]; then
        err "node-pty was not rebuilt"
        exit 1
    fi

    file_type="$(file "$pty_node")"
    if ! printf '%s' "$file_type" | grep -q 'ELF'; then
        err "node-pty is not an ELF binary: $file_type"
        exit 1
    fi

    log "Native modules rebuilt successfully"
}

replace_literal() {
    local target_file="$1"
    local search_text="$2"
    local replacement_text="$3"
    local required="${4:-0}"

    if ! grep -Fq "$search_text" "$target_file"; then
        if [ "$required" -eq 1 ]; then
            err "Expected pattern not found: $search_text"
            exit 1
        fi

        warn "Pattern not found, skipped: $search_text"
        return 0
    fi

    python3 - "$target_file" "$search_text" "$replacement_text" <<'PY'
import sys

path, search_text, replacement_text = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

content = content.replace(search_text, replacement_text)

with open(path, "w", encoding="utf-8") as handle:
    handle.write(content)
PY
}

patch_main_js() {
    local main_js="$BUILD_DIR/.vite/build/main.js"

    if [ ! -f "$main_js" ]; then
        err "main.js not found at $main_js"
        exit 1
    fi

    log "Patching Electron main process bundle..."
    cp "$main_js" "$main_js.bak"

    replace_literal "$main_js" 'require("./native/sparkle.node")' '(() => { throw new Error("sparkle not available on linux") })()'
    # shellcheck disable=SC2016
    replace_literal "$main_js" 'require(`./native/sparkle.node`)' '(() => { throw new Error("sparkle not available on linux") })()'
    replace_literal "$main_js" 'Library/Application Support/Codex' '.config/codex'
    replace_literal "$main_js" 'require("electron-squirrel-startup")' 'false'
    # shellcheck disable=SC2016
    replace_literal "$main_js" 'require(`electron-squirrel-startup`)' 'false'
    replace_literal "$main_js" 'transparent:!0' 'transparent:!1' 1
    replace_literal "$main_js" 'transparent:true' 'transparent:false'
    replace_literal "$main_js" 'vibrancy:' 'vibrancy:null,' 1
    replace_literal "$main_js" 'visualEffectState:' 'visualEffectState:null,'
    replace_literal "$main_js" 'backgroundColor:Z7,backgroundMaterial:null' 'backgroundColor:r?ure:dre,backgroundMaterial:null' 1

    log "main.js patched successfully"
}

extract_icon() {
    local icns_file="$EXTRACTED_DIR/Codex Installer/Codex.app/Contents/Resources/electron.icns"

    if [ -f "$SCRIPT_DIR/codex-icon.png" ]; then
        return 0
    fi

    if [ ! -f "$icns_file" ]; then
        warn "electron.icns not found; using bundled fallback icon"
        return 0
    fi

    if command -v icns2png >/dev/null 2>&1; then
        icns2png -x -s 256 "$icns_file" -o "$SCRIPT_DIR/" >/dev/null 2>&1 || true
        mv "$SCRIPT_DIR/"*256x256*.png "$SCRIPT_DIR/codex-icon.png" 2>/dev/null || true
    elif command -v convert >/dev/null 2>&1; then
        convert "${icns_file}[0]" -resize 256x256 "$SCRIPT_DIR/codex-icon.png" >/dev/null 2>&1 || true
    fi

    if [ ! -f "$SCRIPT_DIR/codex-icon.png" ]; then
        warn "Icon conversion unavailable; keeping fallback electron_512x512x32.png"
    fi
}

write_build_metadata() {
    local output_path="$1"
    local upstream_version
    local release_label

    upstream_version="$(node -e 'console.log(require(process.argv[1]).version)' "$BUILD_DIR/package.json")"
    release_label="${RELEASE_TAG:-$upstream_version}"

    cat > "$output_path" <<EOF
RELEASE_TAG=$release_label
UPSTREAM_VERSION=$upstream_version
TARGET_PLATFORM=$BUILD_PLATFORM
TARGET_ARCH=$BUILD_ARCH
ELECTRON_VERSION=$ELECTRON_VERSION
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SOURCE_DMG=$DMG_FILE
EOF
}

package_release() {
    local upstream_version
    local release_label
    local package_name
    local package_dir
    local archive_path

    upstream_version="$(node -e 'console.log(require(process.argv[1]).version)' "$BUILD_DIR/package.json")"
    release_label="${RELEASE_TAG:-$upstream_version}"
    release_label="${release_label#refs/tags/}"
    package_name="codex-desktop-${release_label}-${BUILD_PLATFORM}-${BUILD_ARCH}"
    package_dir="$ARTIFACTS_DIR/$package_name"
    archive_path="$ARTIFACTS_DIR/$package_name.tar.gz"

    log "Packaging portable release artifact..."
    rm -rf "$package_dir" "$archive_path" "$archive_path.sha256"
    mkdir -p "$package_dir"

    cp -a "$BUILD_DIR" "$package_dir/dist"
    cp "$SCRIPT_DIR/start.sh" "$package_dir/"
    cp "$SCRIPT_DIR/package.json" "$package_dir/"
    cp "$SCRIPT_DIR/pnpm-lock.yaml" "$package_dir/"
    cp "$PROJECT_ROOT/LICENSE" "$package_dir/"
    cp "$PROJECT_ROOT/README.md" "$package_dir/"
    if [ -f "$SCRIPT_DIR/.npmrc" ]; then
        cp "$SCRIPT_DIR/.npmrc" "$package_dir/"
    fi

    (
        cd "$package_dir"
        CI=true pnpm install --prod --frozen-lockfile
    )

    if [ -f "$SCRIPT_DIR/codex-icon.png" ]; then
        cp "$SCRIPT_DIR/codex-icon.png" "$package_dir/"
    else
        cp "$SCRIPT_DIR/electron_512x512x32.png" "$package_dir/codex-icon.png"
    fi

    write_build_metadata "$package_dir/build-metadata.env"

    tar -C "$ARTIFACTS_DIR" -czf "$archive_path" "$package_name"
    (
        cd "$ARTIFACTS_DIR"
        sha256sum "$(basename "$archive_path")" > "$(basename "$archive_path").sha256"
    )

    log "Portable artifact created: $archive_path"
}

install_desktop_entry() {
    local applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local desktop_file="$applications_dir/codex-desktop.desktop"
    local icon_path="$SCRIPT_DIR/codex-icon.png"

    mkdir -p "$applications_dir"

    if [ ! -f "$icon_path" ]; then
        icon_path="$SCRIPT_DIR/electron_512x512x32.png"
    fi

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=Codex
Comment=OpenAI Codex Desktop (Linux Port)
Exec=$SCRIPT_DIR/start.sh
Icon=$icon_path
Type=Application
Categories=Development;IDE;
Terminal=false
StartupWMClass=codex
EOF

    log "Desktop entry installed at $desktop_file"
}

main() {
    parse_args "$@"
    require_commands

    if [ "$CLEAN_OUTPUTS" -eq 1 ]; then
        log "Removing previous build outputs..."
        clean_outputs
    fi

    download_dmg
    verify_dmg
    extract_app
    prepare_working_copy
    rebuild_native_modules
    patch_main_js
    extract_icon

    mkdir -p "$ARTIFACTS_DIR"
    write_build_metadata "$ARTIFACTS_DIR/build-metadata.env"

    chmod +x "$SCRIPT_DIR/start.sh"

    if [ "$INSTALL_DESKTOP_ENTRY" -eq 1 ]; then
        install_desktop_entry
    fi

    if [ "$PACKAGE_RELEASE" -eq 1 ]; then
        package_release
    fi

    printf '\n'
    printf 'Build directory: %s\n' "$BUILD_DIR"
    printf 'Launcher:        %s/start.sh\n' "$SCRIPT_DIR"
    if [ "$PACKAGE_RELEASE" -eq 1 ]; then
        printf 'Artifacts:       %s\n' "$ARTIFACTS_DIR"
    fi
    printf '\n'
}

main "$@"
