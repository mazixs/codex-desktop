#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../scripts/ci-lib.sh
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/ci-lib.sh"
EXTRACTED_DIR="$PROJECT_ROOT/codex_extracted"
APP_UNPACKED="$EXTRACTED_DIR/app_unpacked"
BUILD_DIR="$SCRIPT_DIR/dist"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
NATIVE_BUILD_DIR="$SCRIPT_DIR/native-rebuild"
WEBVIEW_SERVER_TEMPLATE="$SCRIPT_DIR/webview-server.js"
DEFAULT_DMG_FILE="$PROJECT_ROOT/Codex.dmg"
DMG_FILE="$DEFAULT_DMG_FILE"
DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
ELECTRON_VERSION="${ELECTRON_VERSION:-41.3.0}"
BUILD_ARCH="${BUILD_ARCH:-x64}"
BUILD_PLATFORM="linux"
APP_DESKTOP_ID="codex-desktop"
APP_DISPLAY_NAME="Codex Desktop"
APP_STARTUP_WM_CLASS="$APP_DESKTOP_ID"
PACKAGE_PRODUCT_ID="codex-desktop-native"
SKILLS_OVERRIDE_DIR="$PROJECT_ROOT/packaging/skills-overrides"
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

    if [ ! -x "$SCRIPT_DIR/node_modules/.bin/asar" ]; then
        err "Local asar CLI is missing. Run 'pnpm install' in $SCRIPT_DIR first."
        exit 1
    fi
}

resolve_imagemagick() {
    if command -v magick >/dev/null 2>&1; then
        printf 'magick\n'
        return 0
    fi

    if command -v convert >/dev/null 2>&1; then
        printf 'convert\n'
        return 0
    fi

    return 1
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
    "$SCRIPT_DIR/node_modules/.bin/asar" extract \
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

copy_required_dir_contents() {
    local source_dir="$1"
    local destination_dir="$2"

    if [ ! -d "$source_dir" ]; then
        err "Required directory missing: $source_dir"
        exit 1
    fi

    mkdir -p "$destination_dir"
    cp -a "$source_dir/." "$destination_dir/"
}

resolve_main_entry_path() {
    local package_json_path="$1"
    local base_dir="$2"
    local main_entry=""

    if [ ! -f "$package_json_path" ]; then
        err "package.json not found at $package_json_path"
        exit 1
    fi

    main_entry="$(node -e 'const manifest=require(process.argv[1]); if (!manifest.main) { process.exit(1); } process.stdout.write(manifest.main);' "$package_json_path" 2>/dev/null || true)"
    if [ -z "$main_entry" ]; then
        err "Unable to resolve Electron main entry from $package_json_path"
        exit 1
    fi

    printf '%s/%s\n' "$base_dir" "$main_entry"
}

ensure_main_entry_exists() {
    local package_json_path="$1"
    local base_dir="$2"
    local main_entry_path=""
    local discovered_main_js=""

    main_entry_path="$(resolve_main_entry_path "$package_json_path" "$base_dir")"
    if [ -f "$main_entry_path" ]; then
        return 0
    fi

    discovered_main_js="$(find "$base_dir" -maxdepth 4 -type f -name 'main.js' | sort | head -n 5 | tr '\n' ' ' || true)"
    if [ -n "$discovered_main_js" ]; then
        err "Electron main entry not found at $main_entry_path. Discovered main.js candidates: $discovered_main_js"
    else
        err "Electron main entry not found at $main_entry_path and no fallback main.js candidates were discovered under $base_dir"
    fi
    exit 1
}

prepare_working_copy() {
    log "Preparing working copy..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    copy_required_dir_contents "$APP_UNPACKED/.vite" "$BUILD_DIR/.vite"
    copy_required_path "$APP_UNPACKED/webview" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/skills" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/package.json" "$BUILD_DIR"
    copy_required_path "$APP_UNPACKED/node_modules" "$BUILD_DIR"

    if [ -d "$APP_UNPACKED/native" ]; then
        copy_required_path "$APP_UNPACKED/native" "$BUILD_DIR"
    fi

    cp "$WEBVIEW_SERVER_TEMPLATE" "$BUILD_DIR/webview-server.js"
    ensure_main_entry_exists "$BUILD_DIR/package.json" "$BUILD_DIR"
}

apply_packaged_skill_overrides() {
    if [ ! -d "$SKILLS_OVERRIDE_DIR" ]; then
        return 0
    fi

    log "Applying packaged Linux skill overrides..."
    mkdir -p "$BUILD_DIR/skills"
    cp -a "$SKILLS_OVERRIDE_DIR/." "$BUILD_DIR/skills/"
}

apply_linux_desktop_identity() {
    local build_package_json="$BUILD_DIR/package.json"

    if [ ! -f "$build_package_json" ]; then
        err "package.json not found at $build_package_json"
        exit 1
    fi

    log "Applying Linux desktop identity metadata..."
    node - "$build_package_json" "$APP_DESKTOP_ID" "$APP_DISPLAY_NAME" <<'EOF'
const fs = require("node:fs");

const [packageJsonPath, desktopId, displayName] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));

packageJson.desktopName = `${desktopId}.desktop`;
packageJson.productName = displayName;

fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);
EOF
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
    "better-sqlite3": "12.9.0",
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

replace_first_available() {
    local target_file="$1"
    local required="$2"
    shift 2

    while [ "$#" -ge 2 ]; do
        local search_text="$1"
        local replacement_text="$2"
        shift 2

        if grep -Fq "$search_text" "$target_file"; then
            replace_literal "$target_file" "$search_text" "$replacement_text" "$required"
            return 0
        fi
    done

    if [ "$required" -eq 1 ]; then
        err "Expected patch pattern not found in $target_file"
        exit 1
    fi

    warn "No compatible patch pattern found in $(basename "$target_file"), skipped optional patch"
    return 0
}

patch_main_js() {
    local main_bundle=""
    local skills_bundle=""

    ensure_main_entry_exists "$BUILD_DIR/package.json" "$BUILD_DIR"

    # Find the hashed main bundle (main-*.js)
    main_bundle="$(find "$BUILD_DIR/.vite/build" -maxdepth 1 -name 'main-*.js' ! -name '*.map' -type f | head -n 1)"
    if [ -z "$main_bundle" ] || [ ! -f "$main_bundle" ]; then
        err "Main bundle not found in $BUILD_DIR/.vite/build/"
        exit 1
    fi

    # Find the bundle that contains the recommended-skills implementation.
    # Newer upstream builds moved it into product-name-*.js instead of main/deeplinks/bootstrap.
    skills_bundle="$(find "$BUILD_DIR/.vite/build" -maxdepth 1 -name '*.js' ! -name '*.map' -type f -exec grep -l 'skills-curated-cache.json' {} + | head -n 1)"
    if [ -z "$skills_bundle" ] || [ ! -f "$skills_bundle" ]; then
        skills_bundle="$(find "$BUILD_DIR/.vite/build" -maxdepth 1 -name '*.js' ! -name '*.map' -type f -exec grep -l 'bundledRepoRoot' {} + | head -n 1)"
    fi
    if [ -z "$skills_bundle" ] || [ ! -f "$skills_bundle" ]; then
        warn "Recommended-skills bundle not found; falling back to main bundle"
        skills_bundle="$main_bundle"
    fi

    log "Patching Electron main process bundles..."
    log "  main bundle: $(basename "$main_bundle")"
    log "  skills bundle: $(basename "$skills_bundle")"
    cp "$main_bundle" "$main_bundle.bak"
    if [ "$skills_bundle" != "$main_bundle" ]; then
        cp "$skills_bundle" "$skills_bundle.bak"
    fi

    # =====================================================================
    # --- Disable macOS/Windows-specific window appearance properties ---
    # These cause broken rendering on Linux (transparent windows, missing backgrounds)
    # =====================================================================

    # Fully-transparent background used by macOS vibrancy → opaque dark bg.
    # Variable name changes across upstream versions (Hf, So, Sy, etc.) so try known aliases.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'XC=`#00000000`' 'XC=`#1e1e1e`' \
        'ZC=`#00000000`' 'ZC=`#1e1e1e`' \
        'Sy=`#00000000`' 'Sy=`#1e1e1e`' \
        'So="#00000000"' 'So="#1e1e1e"' \
        'cM=`#00000000`' 'cM=`#1e1e1e`' \
        'Hf=`#00000000`' 'Hf=`#1e1e1e`'

    # Keep Linux primary windows opaque, but let light theme use the upstream
    # light background instead of the dark fallback. Otherwise the left sidebar
    # becomes visibly muted in light mode.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'function yw({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!gw(t)?n?{backgroundColor:r?ZC:QC,backgroundMaterial:`none`}:{backgroundColor:XC,backgroundMaterial:`mica`}:{backgroundColor:XC,backgroundMaterial:null}}' \
        'function yw({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!gw(t)?n?{backgroundColor:r?ZC:QC,backgroundMaterial:`none`}:{backgroundColor:XC,backgroundMaterial:`mica`}:e===`linux`&&!gw(t)?{backgroundColor:r?iw:QC,backgroundMaterial:null}:{backgroundColor:XC,backgroundMaterial:null}}' \
        'function bw({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!_w(t)?n?{backgroundColor:r?QC:$C,backgroundMaterial:`none`}:{backgroundColor:ZC,backgroundMaterial:`mica`}:{backgroundColor:ZC,backgroundMaterial:null}}' \
        'function bw({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!_w(t)?n?{backgroundColor:r?QC:$C,backgroundMaterial:`none`}:{backgroundColor:ZC,backgroundMaterial:`mica`}:e===`linux`&&!_w(t)?{backgroundColor:r?aw:$C,backgroundMaterial:null}:{backgroundColor:ZC,backgroundMaterial:null}}' \
        'function jM({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!OM(t)?n?{backgroundColor:r?lM:uM,backgroundMaterial:`none`}:{backgroundColor:cM,backgroundMaterial:`mica`}:{backgroundColor:cM,backgroundMaterial:null}}' \
        'function jM({platform:e,appearance:t,opaqueWindowsEnabled:n,prefersDarkColors:r}){return e===`win32`&&!OM(t)?n?{backgroundColor:r?lM:uM,backgroundMaterial:`none`}:{backgroundColor:cM,backgroundMaterial:`mica`}:e===`linux`&&!OM(t)?{backgroundColor:r?lM:uM,backgroundMaterial:null}:{backgroundColor:cM,backgroundMaterial:null}}'

    replace_literal "$main_bundle" 'transparent:!0' 'transparent:!1'

    # Vibrancy / visualEffectState / backgroundMaterial — try both quote styles
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 0 \
        'vibrancy:"menu"'  'vibrancy:null' \
        'vibrancy:`menu`'  'vibrancy:null'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 0 \
        'visualEffectState:"active"'  'visualEffectState:null' \
        'visualEffectState:`active`'  'visualEffectState:null'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 0 \
        'backgroundMaterial:"mica"'  'backgroundMaterial:null' \
        'backgroundMaterial:`mica`'  'backgroundMaterial:null'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 0 \
        'backgroundMaterial:"none"'  'backgroundMaterial:null' \
        'backgroundMaterial:`none`'  'backgroundMaterial:null'

    # Keep the native menu auto-hidden only on Windows.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        '...process.platform===`win32`?{autoHideMenuBar:!0}:{}' \
        '...process.platform===`win32`?{autoHideMenuBar:!0}:{}' \
        '...process.platform===`win32`||process.platform===`linux`?{autoHideMenuBar:!0}:{}' \
        '...process.platform===`win32`?{autoHideMenuBar:!0}:{}'

    # Remove the native application menu entirely on Linux so it never appears.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'process.platform===`win32`&&k.removeMenu(),k.on(`closed`,()=>{M?.()})' \
        '(process.platform===`win32`||process.platform===`linux`)&&k.removeMenu(),k.on(`closed`,()=>{M?.()})' \
        'process.platform===`win32`&&O.removeMenu(),O.on(`closed`,()=>{j?.()})' \
        '(process.platform===`win32`||process.platform===`linux`)&&O.removeMenu(),O.on(`closed`,()=>{j?.()})' \
        'process.platform===`win32`&&j.removeMenu(),j.on(`closed`,()=>{P?.()})' \
        '(process.platform===`win32`||process.platform===`linux`)&&j.removeMenu(),j.on(`closed`,()=>{P?.()})' \
        'process.platform===`win32`&&O.removeMenu(),process.platform===`linux`&&(O.setMenuBarVisibility(!1),O.webContents.on(`before-input-event`,(e,t)=>{t.type===`keyDown`&&t.alt&&t.shift&&!t.control&&!t.meta&&typeof t.key===`string`&&t.key.toLowerCase()===`k`&&(e.preventDefault(),O.setMenuBarVisibility(!O.isMenuBarVisible()))})),O.on(`closed`,()=>{j?.()})' \
        '(process.platform===`win32`||process.platform===`linux`)&&O.removeMenu(),O.on(`closed`,()=>{j?.()})'

    # Upstream refreshes the global application menu after startup, which reattaches
    # the native menubar on Linux even if the window menu was removed earlier.
    # Force a null application menu on Linux while preserving default behavior elsewhere.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'n.Menu.setApplicationMenu(Ge),H_(h)' \
        'process.platform===`linux`?(n.Menu.setApplicationMenu(null),H_(h)):(n.Menu.setApplicationMenu(Ge),H_(h))' \
        'n.Menu.setApplicationMenu(Ge),U_(h)' \
        'process.platform===`linux`?(n.Menu.setApplicationMenu(null),U_(h)):(n.Menu.setApplicationMenu(Ge),U_(h))' \
        't.Menu.setApplicationMenu(Le),Qp(m)' \
        'process.platform===`linux`?(t.Menu.setApplicationMenu(null),Qp(m)):(t.Menu.setApplicationMenu(Le),Qp(m))' \
        'n.Menu.setApplicationMenu(Ke),rT(h)' \
        'process.platform===`linux`?(n.Menu.setApplicationMenu(null),rT(h)):(n.Menu.setApplicationMenu(Ke),rT(h))'

    # =====================================================================
    # --- Add Linux file manager support ---
    # The upstream fileManager target only defines darwin and win32 platforms.
    # On Linux the "Open folder" button in Skills silently fails because
    # there is no linux entry, so the target is never registered.
    # Add linux support using xdg-open via Electron shell.openPath().
    # Variable/function names change across upstream versions, so try both.
    # =====================================================================

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var lu=jl({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>il(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:uu,args:e=>il(e),open:async({path:e})=>du(e)}});' \
        'var lu=jl({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>il(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:uu,args:e=>il(e),open:async({path:e})=>du(e)},linux:{label:`File Manager`,detect:()=>`xdg-open`,args:e=>[e],open:async({path:e})=>{let t=fu(e);if(t&&(0,o.statSync)(t).isFile()){let e=(0,i.dirname)(t),r=await n.shell.openPath(e);if(r)throw Error(r);return}let r=await n.shell.openPath(t??e);if(r)throw Error(r)}}});' \
        'var ka=$i({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>Ti(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Aa,args:e=>Ti(e),open:async({path:e})=>ja(e)}});' \
        'var ka=$i({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>Ti(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Aa,args:e=>Ti(e),open:async({path:e})=>ja(e)},linux:{label:`File Manager`,detect:()=>`xdg-open`,args:e=>[e],open:async({path:e})=>{let n=Ma(e);if(n&&(0,a.statSync)(n).isFile()){let e=(0,r.dirname)(n),i=await t.shell.openPath(e);if(i)throw Error(i);return}let i=await t.shell.openPath(n??e);if(i)throw Error(i)}}});' \
        'const l_=Ze({id:"fileManager",label:"Finder",icon:"apps/finder.png",kind:"fileManager",darwin:{detect:()=>"open",args:r=>Qc(r)},win32:{label:"File Explorer",icon:"apps/file-explorer.png",detect:u_,args:r=>Qc(r),open:async({path:r})=>d_(r)}})' \
        'const l_=Ze({id:"fileManager",label:"Finder",icon:"apps/finder.png",kind:"fileManager",darwin:{detect:()=>"open",args:r=>Qc(r)},win32:{label:"File Explorer",icon:"apps/file-explorer.png",detect:u_,args:r=>Qc(r),open:async({path:r})=>d_(r)},linux:{label:"File Manager",detect:()=>H("xdg-open"),args:r=>[r],open:async({path:r})=>{let e=r;try{k.statSync(e).isFile()&&(e=q.dirname(e))}catch{}const t=await x.shell.openPath(e);if(t)throw Error(t)}}})' \
        'const Xa=ea({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>pa(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Za,args:e=>pa(e),open:async({path:e})=>Qa(e)}})' \
        'const Xa=ea({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>pa(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Za,args:e=>pa(e),open:async({path:e})=>Qa(e)},linux:{label:`File Manager`,detect:()=>B(`xdg-open`),args:e=>[e],open:async({path:e})=>{let n=e;try{(0,a.statSync)(n).isFile()&&(n=(0,r.dirname)(n))}catch{}let i=await t.shell.openPath(n);if(i)throw Error(i)}}})' \
        'var Cs=Go({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>vo(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ws,args:e=>vo(e),open:async({path:e})=>Ts(e)}});' \
        'var Cs=Go({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>vo(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ws,args:e=>vo(e),open:async({path:e})=>Ts(e)},linux:{label:`File Manager`,detect:()=>`xdg-open`,args:e=>[e],open:async({path:e})=>{let n=Es(e);if(n&&(0,a.statSync)(n).isFile()){let e=(0,r.dirname)(n),i=await t.shell.openPath(e);if(i)throw Error(i);return}let i=await t.shell.openPath(n??e);if(i)throw Error(i)}}});' \
        'var uu=Ml({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>il(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:du,args:e=>il(e),open:async({path:e})=>fu(e)}});' \
        'var uu=Ml({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>il(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:du,args:e=>il(e),open:async({path:e})=>fu(e)},linux:{label:`File Manager`,detect:()=>`xdg-open`,args:e=>[e],open:async({path:e})=>{let t=pu(e);if(t&&(0,o.statSync)(t).isFile()){let e=(0,i.dirname)(t),r=await n.shell.openPath(e);if(r)throw Error(r);return}let r=await n.shell.openPath(t??e);if(r)throw Error(r)}}});' \
        'Ph=th({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>Dm(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Fh,args:e=>Dm(e),open:async({path:e})=>Ih(e)}})' \
        'Ph=th({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>Dm(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Fh,args:e=>Dm(e),open:async({path:e})=>Ih(e)},linux:{label:`File Manager`,detect:()=>`xdg-open`,args:e=>[e],open:async({path:e})=>{let t=Lh(e);if(t&&(0,o.statSync)(t).isFile()){let e=(0,i.dirname)(t),r=await n.shell.openPath(e);if(r)throw Error(r);return}let r=await n.shell.openPath(t??e);if(r)throw Error(r)}}})'

    # Add Linux editor/IDE targets. Upstream ships icons and target definitions
    # for macOS/Windows, but most editor targets have no linux platform entry
    # and are filtered out before detection runs.
    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'function Ml({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,darwinEnv:a,darwinArgs:o,hidden:s}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:s,detect:r,env:a,args:o??Nl,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:s,detect:i,args:Nl,supportsSsh:!0}:void 0}}}' \
        'function Ml({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,linuxDetect:a,darwinEnv:o,darwinArgs:s,linuxArgs:c,hidden:l}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:l,detect:r,env:o,args:s??Nl,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:l,detect:i,args:Nl,supportsSsh:!0}:void 0,linux:a?{label:t,icon:n,kind:`editor`,hidden:l,detect:a,args:c??Nl,supportsSsh:!0}:void 0}}}' \
        'function Nl({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,darwinEnv:a,darwinArgs:o,hidden:s}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:s,detect:r,env:a,args:o??Pl,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:s,detect:i,args:Pl,supportsSsh:!0}:void 0}}}' \
        'function Nl({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,linuxDetect:a,darwinEnv:o,darwinArgs:s,linuxArgs:c,hidden:l}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:l,detect:r,env:o,args:s??Pl,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:l,detect:i,args:Pl,supportsSsh:!0}:void 0,linux:a?{label:t,icon:n,kind:`editor`,hidden:l,detect:a,args:c??Pl,supportsSsh:!0}:void 0}}}' \
        'function nh({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,darwinEnv:a,darwinArgs:o,hidden:s}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:s,detect:r,env:a,args:o??rh,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:s,detect:i,args:rh,supportsSsh:!0}:void 0}}}' \
        'function nh({id:e,label:t,icon:n,darwinDetect:r,win32Detect:i,linuxDetect:a,darwinEnv:o,darwinArgs:s,linuxArgs:c,hidden:l}){return{id:e,platforms:{darwin:r?{label:t,icon:n,kind:`editor`,hidden:l,detect:r,env:o,args:s??rh,supportsSsh:!0}:void 0,win32:i?{label:t,icon:n,kind:`editor`,hidden:l,detect:i,args:rh,supportsSsh:!0}:void 0,linux:a?{label:t,icon:n,kind:`editor`,hidden:l,detect:a,args:c??rh,supportsSsh:!0}:void 0}}}'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'function Pu({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>Ru(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:Vu},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>zu({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:Vu}:void 0}}}' \
        'function Pu({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c,linuxPathCommands:l}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>Ru(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:Vu},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>zu({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:Vu}:void 0,linux:l?{label:t,icon:n,kind:`editor`,detect:()=>l.map(e=>U(e)).find(Boolean)??null,args:Vu}:void 0}}}' \
        'function Fu({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>zu(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:Hu},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>Bu({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:Hu}:void 0}}}' \
        'function Fu({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c,linuxPathCommands:l}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>zu(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:Hu},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>Bu({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:Hu}:void 0,linux:l?{label:t,icon:n,kind:`editor`,detect:()=>l.map(e=>W(e)).find(Boolean)??null,args:Hu}:void 0}}}' \
        'function ag({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>lg(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:fg},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>ug({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:fg}:void 0}}}' \
        'function ag({id:e,label:t,icon:n,toolboxTarget:r,macExecutable:i,windowsPathCommands:a,windowsInstallDirPrefixes:o,windowsInstallExecutables:s,windowsFallbackPaths:c,linuxPathCommands:l}){return{id:e,platforms:{darwin:{label:t,icon:n,kind:`editor`,detect:()=>lg(r,[`/Applications/${t}.app/Contents/MacOS/${i}`],t,i),args:fg},win32:a&&o&&s?{label:t,icon:n,kind:`editor`,detect:()=>ug({pathCommands:a,installDirPrefixes:o,installExecutables:s,fallbackPaths:c}),args:fg}:void 0,linux:l?{label:t,icon:n,kind:`editor`,detect:()=>l.map(e=>K(e)).find(Boolean)??null,args:fg}:void 0}}}'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var Nl=(t,n,r,i,a)=>r!=null&&e.Ct(r)&&(i!=null||a!=null)?Cl({hostConfig:r,location:n,remotePath:a,remoteWorkspaceRoot:i}):Sl(t,n),Pl=Ml({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>Kc([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:Fl});' \
        'var Nl=(t,n,r,i,a)=>r!=null&&e.Ct(r)&&(i!=null||a!=null)?Cl({hostConfig:r,location:n,remotePath:a,remoteWorkspaceRoot:i}):Sl(t,n),Pl=Ml({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>Kc([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:Fl,linuxDetect:()=>U(`antigravity`)});' \
        'var Pl=(t,n,r,i,a)=>r!=null&&e.Ct(r)&&(i!=null||a!=null)?wl({hostConfig:r,location:n,remotePath:a,remoteWorkspaceRoot:i}):Cl(t,n),Fl=Nl({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>Kc([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:Il});' \
        'var Pl=(t,n,r,i,a)=>r!=null&&e.Ct(r)&&(i!=null||a!=null)?wl({hostConfig:r,location:n,remotePath:a,remoteWorkspaceRoot:i}):Cl(t,n),Fl=Nl({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>Kc([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:Il,linuxDetect:()=>W(`antigravity`)});' \
        'ih=nh({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>hm([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:ah})' \
        'ih=nh({id:`antigravity`,label:`Antigravity`,icon:`apps/antigravity.png`,darwinDetect:()=>hm([`/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity`]),win32Detect:ah,linuxDetect:()=>K(`antigravity`)})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var au=Ml({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>su()?.electronBin??null,win32Detect:cu,darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=su();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...ou(...e)]}})' \
        'var au=Ml({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>su()?.electronBin??null,win32Detect:cu,linuxDetect:()=>U(`cursor`),darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=su();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...ou(...e)]}})' \
        'var ou=Nl({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>cu()?.electronBin??null,win32Detect:lu,darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=cu();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...su(...e)]}})' \
        'var ou=Nl({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>cu()?.electronBin??null,win32Detect:lu,linuxDetect:()=>W(`cursor`),darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=cu();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...su(...e)]}})' \
        'var kh=nh({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>jh()?.electronBin??null,win32Detect:Mh,darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=jh();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...Ah(...e)]}})' \
        'var kh=nh({id:`cursor`,label:`Cursor`,icon:`apps/cursor.png`,darwinDetect:()=>jh()?.electronBin??null,win32Detect:Mh,linuxDetect:()=>K(`cursor`),darwinEnv:()=>{let e={...process.env};return e.VSCODE_NODE_OPTIONS=e.NODE_OPTIONS,e.VSCODE_NODE_REPL_EXTERNAL_MODULE=e.NODE_REPL_EXTERNAL_MODULE,delete e.NODE_OPTIONS,delete e.NODE_REPL_EXTERNAL_MODULE,e.ELECTRON_RUN_AS_NODE=`1`,e},darwinArgs:(...e)=>{let t=jh();if(!t)throw Error(`Cursor CLI entrypoint not available`);return[t.cliJs,...Ah(...e)]}})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var Uu=jl({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:Wu,args:Hu},win32:{detect:Gu,args:Hu}});' \
        'var Uu=jl({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:Wu,args:Hu},win32:{detect:Gu,args:Hu},linux:{detect:()=>U(`subl`)??U(`sublime_text`),args:Hu}});' \
        'var Wu=Ml({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:Gu,args:Uu},win32:{detect:Ku,args:Uu}});' \
        'var Wu=Ml({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:Gu,args:Uu},win32:{detect:Ku,args:Uu},linux:{detect:()=>W(`subl`)??W(`sublime_text`),args:Uu}});' \
        'var mg=th({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:hg,args:pg},win32:{detect:gg,args:pg}});' \
        'var mg=th({id:`sublimeText`,label:`Sublime Text`,icon:`apps/sublime-text.png`,kind:`editor`,darwin:{detect:hg,args:pg},win32:{detect:gg,args:pg},linux:{detect:()=>K(`subl`)??K(`sublime_text`),args:pg}});'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var td=Ml({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:nd});' \
        'var td=Ml({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:nd,linuxDetect:()=>U(`code`)});' \
        'var nd=Nl({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:rd});' \
        'var nd=Nl({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:rd,linuxDetect:()=>W(`code`)});' \
        'var Eg=nh({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>hm([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:Dg});' \
        'var Eg=nh({id:`vscode`,label:`VS Code`,icon:`apps/vscode.png`,darwinDetect:()=>hm([`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,`/Applications/Code.app/Contents/Resources/app/bin/code`]),win32Detect:Dg,linuxDetect:()=>K(`code`)});'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var rd=Ml({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:id});' \
        'var rd=Ml({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:id,linuxDetect:()=>U(`code-insiders`)});' \
        'var id=Nl({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:ad});' \
        'var id=Nl({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>Kc([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:ad,linuxDetect:()=>W(`code-insiders`)});' \
        'var Og=nh({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>hm([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:kg});' \
        'var Og=nh({id:`vscodeInsiders`,label:`VS Code Insiders`,icon:`apps/vscode-insiders.png`,darwinDetect:()=>hm([`/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code`,`/Applications/Code - Insiders.app/Contents/Resources/app/bin/code`]),win32Detect:kg,linuxDetect:()=>K(`code-insiders`)});'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var ad=zl({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),od=Ml({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>Kc([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`])})' \
        'var ad=zl({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),od=Ml({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>Kc([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`]),linuxDetect:()=>U(`windsurf`)})' \
        'var od=Bl({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),sd=Nl({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>Kc([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`])})' \
        'var od=Bl({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),sd=Nl({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>Kc([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`]),linuxDetect:()=>W(`windsurf`)})' \
        'var Ag=lh({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),jg=nh({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>hm([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`])})' \
        'var Ag=lh({id:`warp`,label:`Warp`,icon:`apps/warp.png`,appPaths:[`/Applications/Warp.app`],appName:`Warp`}),jg=nh({id:`windsurf`,label:`Windsurf`,icon:`apps/windsurf.png`,darwinDetect:()=>hm([`/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf`]),linuxDetect:()=>K(`windsurf`)})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'var _d={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:vd,args:Hu,open:async({command:e,path:t,location:n})=>{await Sd(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:yd,args:Hu}}};' \
        'var _d={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:vd,args:Hu,open:async({command:e,path:t,location:n})=>{await Sd(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:yd,args:Hu},linux:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:()=>U(`zed`),args:Hu}}};' \
        'var vd={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:yd,args:Uu,open:async({command:e,path:t,location:n})=>{await Cd(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:bd,args:Uu}}};' \
        'var vd={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:yd,args:Uu,open:async({command:e,path:t,location:n})=>{await Cd(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:bd,args:Uu},linux:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:()=>W(`zed`),args:Uu}}};' \
        'var Hg={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:Ug,args:pg,open:async({command:e,path:t,location:n})=>{await qg(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:Wg,args:pg}}};' \
        'var Hg={id:`zed`,platforms:{darwin:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:Ug,args:pg,open:async({command:e,path:t,location:n})=>{await qg(e,t,n)}},win32:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:Wg,args:pg},linux:{label:`Zed`,icon:`apps/zed.png`,kind:`editor`,detect:()=>K(`zed`),args:pg}}};'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Tu=Pu({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]]})' \
        'Tu=Pu({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]],linuxPathCommands:[`android-studio`,`studio`]})' \
        'Eu=Fu({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]]})' \
        'Eu=Fu({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]],linuxPathCommands:[`android-studio`,`studio`]})' \
        'Xh=ag({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]]})' \
        'Xh=ag({id:`androidStudio`,label:`Android Studio`,icon:`apps/android-studio.png`,toolboxTarget:`androidStudio`,macExecutable:`studio`,windowsPathCommands:[`studio64.exe`,`studio.exe`,`studio`],windowsInstallDirPrefixes:[`android studio`],windowsInstallExecutables:[`studio64.exe`,`studio.exe`],windowsFallbackPaths:[[`Android`,`Android Studio`,`bin`,`studio64.exe`],[`Android`,`Android Studio`,`bin`,`studio.exe`]],linuxPathCommands:[`android-studio`,`studio`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Eu=Pu({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`]})' \
        'Eu=Pu({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`],linuxPathCommands:[`idea`,`idea.sh`]})' \
        'Du=Fu({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`]})' \
        'Du=Fu({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`],linuxPathCommands:[`idea`,`idea.sh`]})' \
        'Zh=ag({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`]})' \
        'Zh=ag({id:`intellij`,label:`IntelliJ IDEA`,icon:`apps/intellij.png`,toolboxTarget:`intellij`,macExecutable:`idea`,windowsPathCommands:[`idea64.exe`,`idea.exe`,`idea`],windowsInstallDirPrefixes:[`intellij idea`,`idea`],windowsInstallExecutables:[`idea64.exe`,`idea.exe`],linuxPathCommands:[`idea`,`idea.sh`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Du=Pu({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`]})' \
        'Du=Pu({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`],linuxPathCommands:[`rider`]})' \
        'Ou=Fu({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`]})' \
        'Ou=Fu({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`],linuxPathCommands:[`rider`]})' \
        'Qh=ag({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`]})' \
        'Qh=ag({id:`rider`,label:`Rider`,icon:`apps/rider.png`,toolboxTarget:`rider`,macExecutable:`rider`,windowsPathCommands:[`rider64.exe`,`rider.exe`,`rider`],windowsInstallDirPrefixes:[`rider`],windowsInstallExecutables:[`rider64.exe`,`rider.exe`],linuxPathCommands:[`rider`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Ou=Pu({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`})' \
        'Ou=Pu({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`,linuxPathCommands:[`goland`]})' \
        'ku=Fu({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`})' \
        'ku=Fu({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`,linuxPathCommands:[`goland`]})' \
        '$h=ag({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`})' \
        '$h=ag({id:`goland`,label:`GoLand`,icon:`apps/goland.png`,toolboxTarget:`goland`,macExecutable:`goland`,linuxPathCommands:[`goland`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'ku=Pu({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`})' \
        'ku=Pu({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`,linuxPathCommands:[`rustrover`]})' \
        'Au=Fu({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`})' \
        'Au=Fu({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`,linuxPathCommands:[`rustrover`]})' \
        'eg=ag({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`})' \
        'eg=ag({id:`rustrover`,label:`RustRover`,icon:`apps/rustrover.png`,toolboxTarget:`rustrover`,macExecutable:`rustrover`,linuxPathCommands:[`rustrover`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Au=Pu({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`]})' \
        'Au=Pu({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`],linuxPathCommands:[`pycharm`,`pycharm.sh`]})' \
        'ju=Fu({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`]})' \
        'ju=Fu({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`],linuxPathCommands:[`pycharm`,`pycharm.sh`]})' \
        'tg=ag({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`]})' \
        'tg=ag({id:`pycharm`,label:`PyCharm`,icon:`apps/pycharm.png`,toolboxTarget:`pycharm`,macExecutable:`pycharm`,windowsPathCommands:[`pycharm64.exe`,`pycharm.exe`,`pycharm`],windowsInstallDirPrefixes:[`pycharm`],windowsInstallExecutables:[`pycharm64.exe`,`pycharm.exe`],linuxPathCommands:[`pycharm`,`pycharm.sh`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'ju=Pu({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`]})' \
        'ju=Pu({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`],linuxPathCommands:[`webstorm`,`webstorm.sh`]})' \
        'Mu=Fu({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`]})' \
        'Mu=Fu({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`],linuxPathCommands:[`webstorm`,`webstorm.sh`]})' \
        'ng=ag({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`]})' \
        'ng=ag({id:`webstorm`,label:`WebStorm`,icon:`apps/webstorm.svg`,toolboxTarget:`webstorm`,macExecutable:`webstorm`,windowsPathCommands:[`webstorm64.exe`,`webstorm.exe`,`webstorm`],windowsInstallDirPrefixes:[`webstorm`],windowsInstallExecutables:[`webstorm64.exe`,`webstorm.exe`],linuxPathCommands:[`webstorm`,`webstorm.sh`]})'

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'Mu=Pu({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`]})' \
        'Mu=Pu({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`],linuxPathCommands:[`phpstorm`,`phpstorm.sh`]})' \
        'Nu=Fu({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`]})' \
        'Nu=Fu({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`],linuxPathCommands:[`phpstorm`,`phpstorm.sh`]})' \
        'rg=ag({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`]})' \
        'rg=ag({id:`phpstorm`,label:`PhpStorm`,icon:`apps/phpstorm.png`,toolboxTarget:`phpstorm`,macExecutable:`phpstorm`,windowsPathCommands:[`phpstorm64.exe`,`phpstorm.exe`,`phpstorm`],windowsInstallDirPrefixes:[`phpstorm`],windowsInstallExecutables:[`phpstorm64.exe`,`phpstorm.exe`],linuxPathCommands:[`phpstorm`,`phpstorm.sh`]})'

    # =====================================================================
    # --- Skills path function (JE/yc) in main bundle ---
    # Makes the skills directory discoverable with existence checks and fallback paths
    # =====================================================================

    # shellcheck disable=SC2016
    replace_first_available "$main_bundle" 1 \
        'function Kf(){let e=n.app.getAppPath();if(n.app.isPackaged)return i.join(e,`skills`);let t=i.join(e,`assets`,`skills`);if((0,o.existsSync)(t))return t;let r=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(r)?r:null}' \
        'function Kf(){let e=n.app.getAppPath(),t=i.join(e,`skills`);if((0,o.existsSync)(t))return t;if(n.app.isPackaged)return t;let r=i.join(e,`assets`,`skills`);if((0,o.existsSync)(r))return r;let a=i.join(e,`..`,`skills`);if((0,o.existsSync)(a))return a;let s=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(s)?s:null}' \
        'function qf(){let e=n.app.getAppPath();if(n.app.isPackaged)return i.join(e,`skills`);let t=i.join(e,`assets`,`skills`);if((0,o.existsSync)(t))return t;let r=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(r)?r:null}' \
        'function qf(){let e=n.app.getAppPath(),t=i.join(e,`skills`);if((0,o.existsSync)(t))return t;if(n.app.isPackaged)return t;let r=i.join(e,`assets`,`skills`);if((0,o.existsSync)(r))return r;let a=i.join(e,`..`,`skills`);if((0,o.existsSync)(a))return a;let s=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(s)?s:null}' \
        'function rc(){let e=t.app.getAppPath();if(t.app.isPackaged)return r.join(e,`skills`);let n=r.join(e,`assets`,`skills`);if((0,a.existsSync)(n))return n;let i=r.join(e,`..`,`assets`,`skills`);return(0,a.existsSync)(i)?i:null}' \
        'function rc(){let e=t.app.getAppPath(),n=r.join(e,`skills`);if((0,a.existsSync)(n))return n;if(t.app.isPackaged)return n;let i=r.join(e,`assets`,`skills`);if((0,a.existsSync)(i))return i;let o=r.join(e,`..`,`skills`);if((0,a.existsSync)(o))return o;let s=r.join(e,`..`,`assets`,`skills`);return(0,a.existsSync)(s)?s:null}' \
        'function JE(r){const e=a.platformPath(r),t=x.app.getAppPath();if(x.app.isPackaged)return e.join(t,"skills");const i=e.join(t,"assets","skills");if(k.existsSync(i))return i;const n=e.join(t,"..","assets","skills");return k.existsSync(n)?n:null}' \
        'function JE(r){const e=a.platformPath(r),t=x.app.getAppPath(),i=e.join(t,"skills");if(k.existsSync(i))return i;if(x.app.isPackaged)return i;const n=e.join(t,"assets","skills");if(k.existsSync(n))return n;const o=e.join(t,"..","skills");if(k.existsSync(o))return o;const s=e.join(t,"..","assets","skills");return k.existsSync(s)?s:null}' \
        'function yc(n){let r=e.qt(n),i=t.app.getAppPath();if(t.app.isPackaged)return r.join(i,`skills`);let o=r.join(i,`assets`,`skills`);if((0,a.existsSync)(o))return o;let s=r.join(i,`..`,`assets`,`skills`);return(0,a.existsSync)(s)?s:null}' \
        'function yc(n){let r=e.qt(n),i=t.app.getAppPath(),o=r.join(i,`skills`);if((0,a.existsSync)(o))return o;if(t.app.isPackaged)return o;let s=r.join(i,`assets`,`skills`);if((0,a.existsSync)(s))return s;let c=r.join(i,`..`,`skills`);if((0,a.existsSync)(c))return c;let l=r.join(i,`..`,`assets`,`skills`);return(0,a.existsSync)(l)?l:null}' \
        'function ru(){let e=t.app.getAppPath();if(t.app.isPackaged)return r.join(e,`skills`);let n=r.join(e,`assets`,`skills`);if((0,a.existsSync)(n))return n;let i=r.join(e,`..`,`assets`,`skills`);return(0,a.existsSync)(i)?i:null}' \
        'function ru(){let e=t.app.getAppPath(),n=r.join(e,`skills`);if((0,a.existsSync)(n))return n;if(t.app.isPackaged)return n;let i=r.join(e,`assets`,`skills`);if((0,a.existsSync)(i))return i;let o=r.join(e,`..`,`skills`);if((0,a.existsSync)(o))return o;let s=r.join(e,`..`,`assets`,`skills`);return(0,a.existsSync)(s)?s:null}' \
        'function _v(){let e=n.app.getAppPath();if(n.app.isPackaged)return i.join(e,`skills`);let t=i.join(e,`assets`,`skills`);if((0,o.existsSync)(t))return t;let r=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(r)?r:null}' \
        'function _v(){let e=n.app.getAppPath(),t=i.join(e,`skills`);if((0,o.existsSync)(t))return t;if(n.app.isPackaged)return t;let r=i.join(e,`assets`,`skills`);if((0,o.existsSync)(r))return r;let a=i.join(e,`..`,`skills`);if((0,o.existsSync)(a))return a;let s=i.join(e,`..`,`assets`,`skills`);return(0,o.existsSync)(s)?s:null}'

    # =====================================================================
    # --- Skills loader patches ---
    # In older upstream these live in deeplinks-*.js; in newer upstream
    # they moved to main-*.js.  Determine the target bundle dynamically.
    # =====================================================================

    # --- cM/so/Mk: recommended skills loader — add bundled skill override support ---
    # shellcheck disable=SC2016
    replace_first_available "$skills_bundle" 0 \
        'async function $w({refresh:t=!1,preferWsl:n=!1,bundledRepoRoot:r=null,appServerClient:a}){let o=e.Ct(a.hostConfig)?a.hostConfig.kind===`remote-control`?a.hostConfig.id:a.hostConfig.terminal_command.join(` `):void 0,s=e.Ct(a.hostConfig)?await a.codexHome():Ue({preferWsl:n,hostConfig:a.hostConfig}),c=await a.platformPath(),l=c.join(s,`vendor_imports`),u=c.join(l,`skills`),d=yT(c),f=bT(c),p=f.map(e=>c.join(u,e)),m=c.join(u,d),h=c.join(l,`skills-curated-cache.json`),g=o||!r?null:i.default.resolve(r),_=g?bT(i.default).map(e=>i.default.join(g,e)):null,v=g?i.default.join(g,yT(i.default)):null,y=await _T(h,a),b=t||!y||hT(y),x=await gT(c.join(u,`.git`),a),S=await gT(m,a),C=v?await gT(v,a):!1;try{if(!t&&!x&&!S&&C){let e=await eT({repoRoot:g??u,recommendedRoots:_??p,path:g?i.default:c,appServerClient:a}),t=Date.now();return await vT(h,{fetchedAt:t,skills:e},c,a),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:g??null,error:null}}let e=!1;b&&(x||!S)&&(await uT({repoRoot:u,vendorRoot:l,path:c,appServerClient:a}),await dT(u,a),await fT(u,f,a),e=!0);let n=await eT({repoRoot:u,recommendedRoots:p,path:c,appServerClient:a}),r=e?Date.now():y?.fetchedAt??Date.now();return await vT(h,{fetchedAt:r,skills:n},c,a),{skills:n,fetchedAt:r,source:e?`git`:`cache`,repoRoot:u,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!S&&!x&&C&&g?g:u;return Kw().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),y?{skills:y.skills,fetchedAt:y.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}' \
        'async function $w({refresh:t=!1,preferWsl:n=!1,bundledRepoRoot:r=null,appServerClient:a}){let o=e.Ct(a.hostConfig)?a.hostConfig.kind===`remote-control`?a.hostConfig.id:a.hostConfig.terminal_command.join(` `):void 0,s=e.Ct(a.hostConfig)?await a.codexHome():Ue({preferWsl:n,hostConfig:a.hostConfig}),c=await a.platformPath(),l=c.join(s,`vendor_imports`),u=c.join(l,`skills`),d=yT(c),f=bT(c),p=f.map(e=>c.join(u,e)),m=c.join(u,d),h=c.join(l,`skills-curated-cache.json`),g=o||!r?null:i.default.resolve(r),_=g?bT(i.default).map(e=>i.default.join(g,e)):[],v=g?i.default.join(g,yT(i.default)):null,y=await _T(h,a),b=t||!y||hT(y),x=await gT(c.join(u,`.git`),a),S=await gT(m,a),C=v?await gT(v,a):!1,T=async()=>C&&g?eT({repoRoot:g,recommendedRoots:_,path:i.default,appServerClient:a,sourceTag:`bundled-override`}):[];try{if(!t&&!x&&!S&&C){let e=logBundledSkillOverrides(await T(),`bundled`),t=Date.now();return await vT(h,{fetchedAt:t,skills:e},c,a),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:g??null,error:null}}let e=!1;b&&(x||!S)&&(await uT({repoRoot:u,vendorRoot:l,path:c,appServerClient:a}),await dT(u,a),await fT(u,f,a),e=!0);let n=await eT({repoRoot:u,recommendedRoots:p,path:c,appServerClient:a,sourceTag:e?`git`:`cache`}),r=logBundledSkillOverrides(mergeRecommendedSkillLists(await T().catch(()=>[]),n),e?`git`:`cache`),o=e?Date.now():y?.fetchedAt??Date.now();return await vT(h,{fetchedAt:o,skills:r},c,a),{skills:r,fetchedAt:o,source:e?`git`:`cache`,repoRoot:u,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!S&&!x&&C&&g?g:u,r=await T().catch(()=>[]);return Kw().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),y?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(r,y.skills),`cache`),fetchedAt:y.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:r,fetchedAt:null,source:r.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}' \
        'async function cM({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,appServerClient:r}){let i=_m(r.hostConfig)?r.hostConfig.kind===`remote-control`?r.hostConfig.id:r.hostConfig.terminal_command.join(` `):void 0,a=_m(r.hostConfig)?await r.codexHome():Gg({preferWsl:t,hostConfig:r.hostConfig}),o=await r.platformPath(),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=OM(o),u=kM(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:h.default.resolve(n),g=m?kM(h.default).map(e=>h.default.join(m,e)):null,_=m?h.default.join(m,OM(h.default)):null,v=await EM(p,r),y=e||!v||wM(v),b=await TM(o.join(c,`.git`),r),x=await TM(f,r),S=_?await TM(_,r):!1;try{if(!e&&!b&&!x&&S){let e=await lM({repoRoot:m??c,recommendedRoots:g??d,path:m?h.default:o,appServerClient:r}),t=Date.now();return await DM(p,{fetchedAt:t,skills:e},o,r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;y&&(b||!x)&&(await yM({repoRoot:c,vendorRoot:s,path:o,appServerClient:r}),await bM(c,r),await xM(c,u,r),t=!0);let n=await lM({repoRoot:c,recommendedRoots:d,path:o,appServerClient:r}),i=t?Date.now():v?.fetchedAt??Date.now();return await DM(p,{fetchedAt:i,skills:n},o,r),{skills:n,fetchedAt:i,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!x&&!b&&S&&m?m:c;return tM().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),v?{skills:v.skills,fetchedAt:v.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}' \
        'async function cM({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,appServerClient:r}){let i=_m(r.hostConfig)?r.hostConfig.kind===`remote-control`?r.hostConfig.id:r.hostConfig.terminal_command.join(` `):void 0,a=_m(r.hostConfig)?await r.codexHome():Gg({preferWsl:t,hostConfig:r.hostConfig}),o=await r.platformPath(),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=OM(o),u=kM(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:h.default.resolve(n),g=m?kM(h.default).map(e=>h.default.join(m,e)):[],_=m?h.default.join(m,OM(h.default)):null,v=await EM(p,r),y=e||!v||wM(v),b=await TM(o.join(c,`.git`),r),x=await TM(f,r),S=_?await TM(_,r):!1,T=async()=>S&&m?lM({repoRoot:m,recommendedRoots:g,path:h.default,appServerClient:r,sourceTag:`bundled-override`}):[];try{if(!e&&!b&&!x&&S){let e=logBundledSkillOverrides(await T(),`bundled`),t=Date.now();return await DM(p,{fetchedAt:t,skills:e},o,r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;y&&(b||!x)&&(await yM({repoRoot:c,vendorRoot:s,path:o,appServerClient:r}),await bM(c,r),await xM(c,u,r),t=!0);let n=await lM({repoRoot:c,recommendedRoots:d,path:o,appServerClient:r,sourceTag:t?`git`:`cache`}),i=logBundledSkillOverrides(mergeRecommendedSkillLists(await T().catch(()=>[]),n),t?`git`:`cache`),a=t?Date.now():v?.fetchedAt??Date.now();return await DM(p,{fetchedAt:a,skills:i},o,r),{skills:i,fetchedAt:a,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!x&&!b&&S&&m?m:c,i=await T().catch(()=>[]);return tM().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),v?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(i,v.skills),`cache`),fetchedAt:v.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:i,fetchedAt:null,source:i.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}' \
        'async function so({refresh:r=!1,preferWsl:e=!1,bundledRepoRoot:t=null,hostConfig:i}){const n=a.isRemoteHostConfig(i)?i.terminal_command.join(" "):void 0,o=a.isRemoteHostConfig(i)?await a.resolveRemoteSshCodexHome(i):a.resolveCodexHome({preferWsl:e}),s=a.platformPath(i),c=s.join(o,"vendor_imports"),l=s.join(c,"skills"),u=ix(s),d=ox(s),p=d.map(E=>s.join(l,E)),h=s.join(l,u),f=s.join(c,"skills-curated-cache.json"),m=n||!t?null:s.resolve(t),g=m?d.map(E=>s.join(m,E)):null,v=m?s.join(m,u):null,b=await rx(f,i),w=r||!b||nx(b),D=await xe(s.join(l,".git"),i),_=await xe(h,i),I=v?await xe(v,i):!1;try{if(!r&&!D&&!_&&I){const $=await Ms({repoRoot:m??l,recommendedRoots:g??p,path:s,hostConfig:i}),O=Date.now();return await Us(f,{fetchedAt:O,skills:$},i),{skills:$,fetchedAt:O,source:"bundled",repoRoot:m??null,error:null}}let E=!1;w&&(D||!_)&&(await Yw({repoRoot:l,vendorRoot:c,hostConfig:i}),await Qw(l,i),await ex(l,d,i),E=!0);const S=await Ms({repoRoot:l,recommendedRoots:p,path:s,hostConfig:i}),P=E?Date.now():b?.fetchedAt??Date.now();return await Us(f,{fetchedAt:P,skills:S},i),{skills:S,fetchedAt:P,source:E?"git":"cache",repoRoot:l,error:null}}catch(E){const S=E instanceof Error?E.message:String(E),P=!_&&!D&&I&&m?m:l;return Uw().warning("Failed to load recommended skills",{safe:{},sensitive:{error:E}}),b?{skills:b.skills,fetchedAt:b.fetchedAt,source:"cache",repoRoot:P,error:S}:{skills:[],fetchedAt:null,source:"cache",repoRoot:P,error:S}}}' \
        'async function so({refresh:r=!1,preferWsl:e=!1,bundledRepoRoot:t=null,hostConfig:i}){const n=a.isRemoteHostConfig(i)?i.terminal_command.join(" "):void 0,o=a.isRemoteHostConfig(i)?await a.resolveRemoteSshCodexHome(i):a.resolveCodexHome({preferWsl:e}),s=a.platformPath(i),c=s.join(o,"vendor_imports"),l=s.join(c,"skills"),u=ix(s),d=ox(s),p=d.map(E=>s.join(l,E)),h=s.join(l,u),f=s.join(c,"skills-curated-cache.json"),m=n||!t?null:s.resolve(t),g=m?d.map(E=>s.join(m,E)):[],v=m?s.join(m,u):null,b=await rx(f,i),w=r||!b||nx(b),D=await xe(s.join(l,".git"),i),_=await xe(h,i),I=v?await xe(v,i):!1,Q=async()=>I&&m?Ms({repoRoot:m,recommendedRoots:g,path:s,hostConfig:i}):[];try{if(!r&&!D&&!_&&I){const $=await Q(),O=Date.now();return await Us(f,{fetchedAt:O,skills:$},i),{skills:$,fetchedAt:O,source:"bundled",repoRoot:m??null,error:null}}let E=!1;w&&(D||!_)&&(await Yw({repoRoot:l,vendorRoot:c,hostConfig:i}),await Qw(l,i),await ex(l,d,i),E=!0);const S=await Ms({repoRoot:l,recommendedRoots:p,path:s,hostConfig:i}),R=await Q().catch(()=>[]),P=mergeRecommendedSkillLists(R,S),F=E?Date.now():b?.fetchedAt??Date.now();return await Us(f,{fetchedAt:F,skills:P},i),{skills:P,fetchedAt:F,source:E?"git":"cache",repoRoot:l,error:null}}catch(E){const S=E instanceof Error?E.message:String(E),P=!_&&!D&&I&&m?m:l,F=await Q().catch(()=>[]);return Uw().warning("Failed to load recommended skills",{safe:{},sensitive:{error:E}}),b?{skills:mergeRecommendedSkillLists(F,b.skills),fetchedAt:b.fetchedAt,source:"cache",repoRoot:P,error:S}:{skills:F,fetchedAt:null,source:F.length>0?"bundled":"cache",repoRoot:P,error:S}}}function mergeRecommendedSkillLists(r,e){const t=new Map;for(const i of[...r,...e])t.has(i.id)||t.set(i.id,i);return Array.from(t.values()).sort((i,n)=>i.name.localeCompare(n.name))}' \
        'async function Mk({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,hostConfig:r}){let i=jp(r)?r.terminal_command.join(` `):void 0,a=jp(r)?await __(r):g_({preferWsl:t,hostConfig:r}),o=b_(r),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=Qk(o),u=$k(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:o.resolve(n),h=m?u.map(e=>o.join(m,e)):null,g=m?o.join(m,l):null,_=await Xk(p,r),v=e||!_||Jk(_),y=await Yk(o.join(c,`.git`),r),b=await Yk(f,r),x=g?await Yk(g,r):!1;try{if(!e&&!y&&!b&&x){let e=await Nk({repoRoot:m??c,recommendedRoots:h??d,path:o,hostConfig:r}),t=Date.now();return await Zk(p,{fetchedAt:t,skills:e},r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;v&&(y||!b)&&(await Uk({repoRoot:c,vendorRoot:s,hostConfig:r}),await Wk(c,r),await Gk(c,u,r),t=!0);let n=await Nk({repoRoot:c,recommendedRoots:d,path:o,hostConfig:r}),i=t?Date.now():_?.fetchedAt??Date.now();return await Zk(p,{fetchedAt:i,skills:n},r),{skills:n,fetchedAt:i,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!b&&!y&&x&&m?m:c;return Tk().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),_?{skills:_.skills,fetchedAt:_.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}' \
        'async function Mk({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,hostConfig:r}){let i=jp(r)?r.terminal_command.join(` `):void 0,a=jp(r)?await __(r):g_({preferWsl:t,hostConfig:r}),o=b_(r),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=Qk(o),u=$k(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:o.resolve(n),h=m?u.map(e=>o.join(m,e)):[],g=m?o.join(m,l):null,_=await Xk(p,r),v=e||!_||Jk(_),y=await Yk(o.join(c,`.git`),r),b=await Yk(f,r),x=g?await Yk(g,r):!1,S=async()=>x&&m?Nk({repoRoot:m,recommendedRoots:h,path:o,hostConfig:r,sourceTag:`bundled-override`}):[];try{if(!e&&!y&&!b&&x){let e=logBundledSkillOverrides(await S(),`bundled`),t=Date.now();return await Zk(p,{fetchedAt:t,skills:e},r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;v&&(y||!b)&&(await Uk({repoRoot:c,vendorRoot:s,hostConfig:r}),await Wk(c,r),await Gk(c,u,r),t=!0);let n=await Nk({repoRoot:c,recommendedRoots:d,path:o,hostConfig:r,sourceTag:t?`git`:`cache`}),i=logBundledSkillOverrides(mergeRecommendedSkillLists(await S(),n),t?`git`:`cache`),a=t?Date.now():_?.fetchedAt??Date.now();return await Zk(p,{fetchedAt:a,skills:i},r),{skills:i,fetchedAt:a,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!b&&!y&&x&&m?m:c,i=await S().catch(()=>[]);return Tk().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),_?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(i,_.skills),`cache`),fetchedAt:_.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:i,fetchedAt:null,source:i.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}' \
        'async function KF({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,appServerClient:r}){let i=hm(r.hostConfig)?r.hostConfig.kind===`remote-control`?r.hostConfig.id:r.hostConfig.terminal_command.join(` `):void 0,a=hm(r.hostConfig)?await r.codexHome():eg({preferWsl:t,hostConfig:r.hostConfig}),o=await r.platformPath(),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=fI(o),u=pI(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:h.default.resolve(n),g=m?pI(h.default).map(e=>h.default.join(m,e)):null,_=m?h.default.join(m,fI(h.default)):null,v=await uI(p,r),y=e||!v||cI(v),b=await lI(o.join(c,`.git`),r),x=await lI(f,r),S=_?await lI(_,r):!1;try{if(!e&&!b&&!x&&S){let e=await qF({repoRoot:m??c,recommendedRoots:g??d,path:m?h.default:o,appServerClient:r}),t=Date.now();return await dI(p,{fetchedAt:t,skills:e},o,r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;y&&(b||!x)&&(await rI({repoRoot:c,vendorRoot:s,path:o,appServerClient:r}),await iI(c,r),await aI(c,u,r),t=!0);let n=await qF({repoRoot:c,recommendedRoots:d,path:o,appServerClient:r}),i=t?Date.now():v?.fetchedAt??Date.now();return await dI(p,{fetchedAt:i,skills:n},o,r),{skills:n,fetchedAt:i,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!x&&!b&&S&&m?m:c;return zF().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),v?{skills:v.skills,fetchedAt:v.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}' \
        'async function KF({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,appServerClient:r}){let i=hm(r.hostConfig)?r.hostConfig.kind===`remote-control`?r.hostConfig.id:r.hostConfig.terminal_command.join(` `):void 0,a=hm(r.hostConfig)?await r.codexHome():eg({preferWsl:t,hostConfig:r.hostConfig}),o=await r.platformPath(),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=fI(o),u=pI(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:h.default.resolve(n),g=m?pI(h.default).map(e=>h.default.join(m,e)):null,_=m?h.default.join(m,fI(h.default)):null,v=await uI(p,r),y=e||!v||cI(v),b=await lI(o.join(c,`.git`),r),x=await lI(f,r),S=_?await lI(_,r):!1,T=async()=>S&&m?qF({repoRoot:m,recommendedRoots:g??d,path:m?h.default:o,appServerClient:r,sourceTag:`bundled-override`}):[];try{if(!e&&!b&&!x&&S){let e=logBundledSkillOverrides(await T(),`bundled`),t=Date.now();return await dI(p,{fetchedAt:t,skills:e},o,r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;y&&(b||!x)&&(await rI({repoRoot:c,vendorRoot:s,path:o,appServerClient:r}),await iI(c,r),await aI(c,u,r),t=!0);let n=await qF({repoRoot:c,recommendedRoots:d,path:o,appServerClient:r,sourceTag:t?`git`:`cache`}),i=logBundledSkillOverrides(mergeRecommendedSkillLists(await T(),n),t?`git`:`cache`),a=t?Date.now():v?.fetchedAt??Date.now();return await dI(p,{fetchedAt:a,skills:i},o,r),{skills:i,fetchedAt:a,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!x&&!b&&S&&m?m:c,i=await T().catch(()=>[]);return zF().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),v?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(i,v.skills),`cache`),fetchedAt:v.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:i,fetchedAt:null,source:i.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}' \
        'async function tT({refresh:t=!1,preferWsl:n=!1,bundledRepoRoot:r=null,appServerClient:a}){let o=e.Ct(a.hostConfig)?a.hostConfig.kind===`remote-control`?a.hostConfig.id:a.hostConfig.terminal_command.join(` `):void 0,s=e.Ct(a.hostConfig)?await a.codexHome():Ue({preferWsl:n,hostConfig:a.hostConfig}),c=await a.platformPath(),l=c.join(s,`vendor_imports`),u=c.join(l,`skills`),d=xT(c),f=ST(c),p=f.map(e=>c.join(u,e)),m=c.join(u,d),h=c.join(l,`skills-curated-cache.json`),g=o||!r?null:i.default.resolve(r),_=g?ST(i.default).map(e=>i.default.join(g,e)):null,v=g?i.default.join(g,xT(i.default)):null,y=await yT(h,a),b=t||!y||_T(y),x=await vT(c.join(u,`.git`),a),S=await vT(m,a),C=v?await vT(v,a):!1;try{if(!t&&!x&&!S&&C){let e=await nT({repoRoot:g??u,recommendedRoots:_??p,path:g?i.default:c,appServerClient:a}),t=Date.now();return await bT(h,{fetchedAt:t,skills:e},c,a),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:g??null,error:null}}let e=!1;b&&(x||!S)&&(await fT({repoRoot:u,vendorRoot:l,path:c,appServerClient:a}),await pT(u,a),await mT(u,f,a),e=!0);let n=await nT({repoRoot:u,recommendedRoots:p,path:c,appServerClient:a}),r=e?Date.now():y?.fetchedAt??Date.now();return await bT(h,{fetchedAt:r,skills:n},c,a),{skills:n,fetchedAt:r,source:e?`git`:`cache`,repoRoot:u,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!S&&!x&&C&&g?g:u;return Jw().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),y?{skills:y.skills,fetchedAt:y.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}' \
        'async function tT({refresh:t=!1,preferWsl:n=!1,bundledRepoRoot:r=null,appServerClient:a}){let o=e.Ct(a.hostConfig)?a.hostConfig.kind===`remote-control`?a.hostConfig.id:a.hostConfig.terminal_command.join(` `):void 0,s=e.Ct(a.hostConfig)?await a.codexHome():Ue({preferWsl:n,hostConfig:a.hostConfig}),c=await a.platformPath(),l=c.join(s,`vendor_imports`),u=c.join(l,`skills`),d=xT(c),f=ST(c),p=f.map(e=>c.join(u,e)),m=c.join(u,d),h=c.join(l,`skills-curated-cache.json`),g=o||!r?null:i.default.resolve(r),_=g?ST(i.default).map(e=>i.default.join(g,e)):[],v=g?i.default.join(g,xT(i.default)):null,y=await yT(h,a),b=t||!y||_T(y),x=await vT(c.join(u,`.git`),a),S=await vT(m,a),C=v?await vT(v,a):!1,T=async()=>C&&g?nT({repoRoot:g,recommendedRoots:_,path:i.default,appServerClient:a,sourceTag:`bundled-override`}):[];try{if(!t&&!x&&!S&&C){let e=logBundledSkillOverrides(await T(),`bundled`),t=Date.now();return await bT(h,{fetchedAt:t,skills:e},c,a),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:g??null,error:null}}let e=!1;b&&(x||!S)&&(await fT({repoRoot:u,vendorRoot:l,path:c,appServerClient:a}),await pT(u,a),await mT(u,f,a),e=!0);let n=await nT({repoRoot:u,recommendedRoots:p,path:c,appServerClient:a,sourceTag:e?`git`:`cache`}),r=logBundledSkillOverrides(mergeRecommendedSkillLists(await T().catch(()=>[]),n),e?`git`:`cache`),o=e?Date.now():y?.fetchedAt??Date.now();return await bT(h,{fetchedAt:o,skills:r},c,a),{skills:r,fetchedAt:o,source:e?`git`:`cache`,repoRoot:u,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!S&&!x&&C&&g?g:u,r=await T().catch(()=>[]);return Jw().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),y?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(r,y.skills),`cache`),fetchedAt:y.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:r,fetchedAt:null,source:r.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}'

    # --- lM/Ms/Nk: skill enumerator — add sourceTag + helper functions ---
    # shellcheck disable=SC2016
    replace_first_available "$skills_bundle" 0 \
        'async function eT({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r}){let i=new Map,a=await Promise.all(t.map(async t=>tT({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await I.readFile(i,r);return`data:${a};base64,${Buffer.from(e).toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,t){let n=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return n.length>0&&Kw().info(`Using bundled skill overrides`,{safe:{skillIds:n,baseSource:t},sensitive:{}}),e}async function eT({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>tT({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'async function lM({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r}){let i=new Map,a=await Promise.all(t.map(async t=>uM({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await z.readFile(i,r);return`data:${a};base64,${Buffer.from(e).toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,n){let r=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return r.length>0&&tM().info(`Using bundled skill overrides`,{safe:{skillIds:r,baseSource:n},sensitive:{}}),e}async function lM({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>uM({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'async function Ms({repoRoot:r,recommendedRoots:e,path:t,hostConfig:i}){const n=new Map,o=await Promise.all(e.map(async s=>Gw({recommendedRoot:s,repoRoot:r,path:t,hostConfig:i})));for(const s of o)for(const c of s)n.has(c.id)||n.set(c.id,c);return Array.from(n.values()).sort((s,c)=>s.name.localeCompare(c.name))}' \
        'function skillIconMimeType(r){switch(r){case".svg":return"image/svg+xml";case".png":return"image/png";case".jpg":case".jpeg":return"image/jpeg";case".webp":return"image/webp";default:return null}}async function normalizeSkillIconUrl(r,e,t,i){if(!r)return null;if(/^https?:\/\//i.test(r)||r.startsWith("data:"))return r;const n=t.isAbsolute(r)?r:t.resolve(e,r),o=skillIconMimeType(t.extname(n).toLowerCase());if(!o)return n;try{const s=await a.fsUtils.readFile(n,i);return"data:"+o+";base64,"+Buffer.from(s).toString("base64")}catch{return n}}async function Ms({repoRoot:r,recommendedRoots:e,path:t,hostConfig:i}){const n=new Map,o=await Promise.all(e.map(async s=>Gw({recommendedRoot:s,repoRoot:r,path:t,hostConfig:i})));for(const s of o)for(const c of s)n.has(c.id)||n.set(c.id,c);return Array.from(n.values()).sort((s,c)=>s.name.localeCompare(c.name))}' \
        'async function Nk({repoRoot:e,recommendedRoots:t,path:n,hostConfig:r}){let i=new Map,a=await Promise.all(t.map(async t=>Pk({recommendedRoot:t,repoRoot:e,path:n,hostConfig:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await F.readFileBase64(i,r);return`data:${a};base64,${e.toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,t){let n=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return n.length>0&&Tk().info(`Using bundled skill overrides`,{safe:{skillIds:n,baseSource:t},sensitive:{}}),e}async function Nk({repoRoot:e,recommendedRoots:t,path:n,hostConfig:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>Pk({recommendedRoot:t,repoRoot:e,path:n,hostConfig:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'async function qF({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r}){let i=new Map,a=await Promise.all(t.map(async t=>JF({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await R.readFile(i,r);return`data:${a};base64,${Buffer.from(e).toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,t){let n=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return n.length>0&&zF().info(`Using bundled skill overrides`,{safe:{skillIds:n,baseSource:t},sensitive:{}}),e}async function qF({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>JF({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'async function nT({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r}){let i=new Map,a=await Promise.all(t.map(async t=>rT({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}' \
        'function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await I.readFile(i,r);return`data:${a};base64,${Buffer.from(e).toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,t){let n=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return n.length>0&&Jw().info(`Using bundled skill overrides`,{safe:{skillIds:n,baseSource:t},sensitive:{}}),e}async function nT({repoRoot:e,recommendedRoots:t,path:n,appServerClient:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>rT({recommendedRoot:t,repoRoot:e,path:n,appServerClient:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}'

    # --- uM/Gw/Pk: individual skill loader — add icon normalization + source tagging ---
    # shellcheck disable=SC2016
    replace_first_available "$skills_bundle" 0 \
        'async function tT({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r}){if(!await gT(e,r))return[];let i=await I.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await I.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await gT(s,r))return null;let c=iT(await I.readFile(s,r)),l=await oT({path:n,appServerClient:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await cT({path:n,appServerClient:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?mT(n,t,a):mT(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}' \
        'async function tT({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r,sourceTag:i=null}){if(!await gT(e,r))return[];let a=await I.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await I.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await gT(c,r))return null;let l=iT(await I.readFile(c,r)),u=await oT({path:n,appServerClient:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await cT({path:n,appServerClient:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?mT(n,t,o):mT(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}' \
        'async function uM({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r}){if(!await TM(e,r))return[];let i=await z.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await z.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await TM(s,r))return null;let c=pM(await z.readFile(s,r)),l=await hM({path:n,appServerClient:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await _M({path:n,appServerClient:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?CM(n,t,a):CM(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}' \
        'async function uM({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r,sourceTag:i=null}){if(!await TM(e,r))return[];let a=await z.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await z.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await TM(c,r))return null;let l=pM(await z.readFile(c,r)),u=await hM({path:n,appServerClient:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await _M({path:n,appServerClient:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?CM(n,t,o):CM(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}' \
        'async function Gw({recommendedRoot:r,repoRoot:e,path:t,hostConfig:i}){if(!await xe(r,i))return[];const n=await a.fsUtils.readdir(r,i);return(await Promise.all(n.map(async s=>{if(s.startsWith("."))return null;const c=t.join(r,s),u=(await a.fsUtils.stat(c,i)).isDirectory(),d=u?t.join(c,"SKILL.md"):c;if(!await xe(d,i))return null;const p=await a.fsUtils.readFile(d,i),h=Vw(p),f=await Kw({path:t,hostConfig:i,skillRoot:c}),m=u?s:t.parse(s).name,g=h.description??h.shortDescription??m,v=await Xw({path:t,hostConfig:i,skillRoot:c,skillId:m,iconSmall:h.iconSmall??f.iconSmall??null,iconLarge:h.iconLarge??f.iconLarge??null,isDirectory:u}),b=u?Ns(t,e,c):Ns(t,e,d);return{id:m,name:h.name??m,description:g,shortDescription:h.shortDescription??f.shortDescription,iconSmall:v.iconSmall,iconLarge:v.iconLarge,repoPath:b}}))).filter(s=>s!=null)}' \
        'async function Gw({recommendedRoot:r,repoRoot:e,path:t,hostConfig:i}){if(!await xe(r,i))return[];const n=await a.fsUtils.readdir(r,i);return(await Promise.all(n.map(async s=>{if(s.startsWith("."))return null;const c=t.join(r,s),u=(await a.fsUtils.stat(c,i)).isDirectory(),d=u?t.join(c,"SKILL.md"):c;if(!await xe(d,i))return null;const p=await a.fsUtils.readFile(d,i),h=Vw(p),f=await Kw({path:t,hostConfig:i,skillRoot:c}),m=u?s:t.parse(s).name,g=h.description??h.shortDescription??m,v=await Xw({path:t,hostConfig:i,skillRoot:c,skillId:m,iconSmall:h.iconSmall??f.iconSmall??null,iconLarge:h.iconLarge??f.iconLarge??null,isDirectory:u}),b=u?Ns(t,e,c):Ns(t,e,d);return{id:m,name:h.name??m,description:g,shortDescription:h.shortDescription??f.shortDescription,iconSmall:await normalizeSkillIconUrl(v.iconSmall,c,t,i),iconLarge:await normalizeSkillIconUrl(v.iconLarge,c,t,i),repoPath:b}}))).filter(s=>s!=null)}' \
        'async function Pk({recommendedRoot:e,repoRoot:t,path:n,hostConfig:r}){if(!await Yk(e,r))return[];let i=await F.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await F.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await Yk(s,r))return null;let c=Lk(await F.readFile(s,r)),l=await zk({path:n,hostConfig:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await Vk({path:n,hostConfig:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?qk(n,t,a):qk(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}' \
        'async function Pk({recommendedRoot:e,repoRoot:t,path:n,hostConfig:r,sourceTag:i=null}){if(!await Yk(e,r))return[];let a=await F.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await F.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await Yk(c,r))return null;let l=Lk(await F.readFile(c,r)),u=await zk({path:n,hostConfig:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await Vk({path:n,hostConfig:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?qk(n,t,o):qk(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}' \
        'async function JF({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r}){if(!await lI(e,r))return[];let i=await R.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await R.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await lI(s,r))return null;let c=ZF(await R.readFile(s,r)),l=await $F({path:n,appServerClient:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await tI({path:n,appServerClient:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?sI(n,t,a):sI(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}' \
        'async function JF({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r,sourceTag:i=null}){if(!await lI(e,r))return[];let a=await R.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await R.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await lI(c,r))return null;let l=ZF(await R.readFile(c,r)),u=await $F({path:n,appServerClient:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await tI({path:n,appServerClient:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?sI(n,t,o):sI(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}' \
        'async function rT({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r}){if(!await vT(e,r))return[];let i=await I.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await I.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await vT(s,r))return null;let c=oT(await I.readFile(s,r)),l=await cT({path:n,appServerClient:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await uT({path:n,appServerClient:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?gT(n,t,a):gT(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}' \
        'async function rT({recommendedRoot:e,repoRoot:t,path:n,appServerClient:r,sourceTag:i=null}){if(!await vT(e,r))return[];let a=await I.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await I.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await vT(c,r))return null;let l=oT(await I.readFile(c,r)),u=await cT({path:n,appServerClient:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await uT({path:n,appServerClient:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?gT(n,t,o):gT(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}'

    # --- jM/Ls/tA: skill resolver — prioritize bundled skills over remote ---
    # shellcheck disable=SC2016
    replace_first_available "$skills_bundle" 0 \
        'async function ST({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:a}){let o=CT(e,n,r);if(await wT(o,a))return o;if(!t)return null;let s=CT(t,n,i.default);return await wT(s,a)?s:null}' \
        'async function ST({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:a}){if(t){let o=CT(t,n,i.default);if(await wT(o,a))return o}let s=CT(e,n,r);return await wT(s,a)?s:null}' \
        'async function jM({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:i}){let a=MM(e,n,r);if(await NM(a,i))return a;if(!t)return null;let o=MM(t,n,h.default);return await NM(o,i)?o:null}' \
        'async function jM({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:i}){if(t){let a=MM(t,n,h.default);if(await NM(a,i))return a}let o=MM(e,n,r);return await NM(o,i)?o:null}' \
        'async function Ls({repoRoot:r,bundledRepoRoot:e,repoPath:t,hostConfig:i}){const n=Bs(r,t,i);if(await co(n,i))return n;if(!e)return null;const o=Bs(e,t,i);return await co(o,i)?o:null}' \
        'async function Ls({repoRoot:r,bundledRepoRoot:e,repoPath:t,hostConfig:i}){if(e){const o=Bs(e,t,i);if(await co(o,i))return o}const n=Bs(r,t,i);return await co(n,i)?n:null}' \
        'async function tA({repoRoot:e,bundledRepoRoot:t,repoPath:n,hostConfig:r}){let i=nA(e,n,r);if(await rA(i,r))return i;if(!t)return null;let a=nA(t,n,r);return await rA(a,r)?a:null}' \
        'async function tA({repoRoot:e,bundledRepoRoot:t,repoPath:n,hostConfig:r}){if(t){let i=nA(t,n,r);if(await rA(i,r))return i}let a=nA(e,n,r);return await rA(a,r)?a:null}' \
        'async function hI({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:i}){let a=gI(e,n,r);if(await _I(a,i))return a;if(!t)return null;let o=gI(t,n,h.default);return await _I(o,i)?o:null}' \
        'async function hI({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:i}){if(t){let a=gI(t,n,h.default);if(await _I(a,i))return a}let o=gI(e,n,r);return await _I(o,i)?o:null}' \
        'async function wT({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:a}){let o=TT(e,n,r);if(await ET(o,a))return o;if(!t)return null;let s=TT(t,n,i.default);return await ET(s,a)?s:null}' \
        'async function wT({repoRoot:e,bundledRepoRoot:t,repoPath:n,path:r,appServerClient:a}){if(t){let o=TT(t,n,i.default);if(await ET(o,a))return o}let s=TT(e,n,r);return await ET(s,a)?s:null}'

    # Verify patched bundles parse correctly
    node --check "$main_bundle"
    if [ "$skills_bundle" != "$main_bundle" ]; then
        node --check "$skills_bundle"
    fi

    log "Bundles patched successfully"
}

extract_icon() {
    local icns_file="$EXTRACTED_DIR/Codex Installer/Codex.app/Contents/Resources/electron.icns"
    local imagemagick_bin=""

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
    else
        imagemagick_bin="$(resolve_imagemagick || true)"
        if [ -n "$imagemagick_bin" ]; then
            "$imagemagick_bin" "${icns_file}[0]" -resize 512x512 "$SCRIPT_DIR/codex-icon.png" >/dev/null 2>&1 || true
        fi
    fi

    if [ ! -f "$SCRIPT_DIR/codex-icon.png" ]; then
        warn "Icon conversion unavailable; keeping fallback electron_512x512x32.png"
    fi
}

generate_icon_set() {
    local source_icon="$SCRIPT_DIR/codex-icon.png"
    local icons_root="$ARTIFACTS_DIR/icons/hicolor"
    local imagemagick_bin=""
    local size=""

    if [ ! -f "$source_icon" ]; then
        source_icon="$SCRIPT_DIR/electron_512x512x32.png"
    fi

    if [ ! -f "$source_icon" ]; then
        warn "No source icon available; skipping icon set generation"
        return 0
    fi

    imagemagick_bin="$(resolve_imagemagick || true)"
    if [ -z "$imagemagick_bin" ]; then
        warn "ImageMagick not found; skipping icon set generation"
        return 0
    fi

    rm -rf "$icons_root"
    for size in 16 24 32 48 64 128 256 512; do
        local size_dir="$icons_root/${size}x${size}/apps"
        mkdir -p "$size_dir"
        "$imagemagick_bin" "$source_icon" -background none -resize "${size}x${size}" "$size_dir/${APP_DESKTOP_ID}.png"
    done
}

resolve_release_version() {
    local upstream_version="$1"
    local version

    if [ -n "${RELEASE_TAG:-}" ]; then
        version="${RELEASE_TAG#v}"
    else
        version="$upstream_version"
    fi

    printf '%s\n' "$version"
}

write_build_metadata() {
    local output_path="$1"
    local release_version="$2"
    local upstream_version
    local release_label
    local portable_dirname
    local portable_filename

    upstream_version="$(node -e 'console.log(require(process.argv[1]).version)' "$BUILD_DIR/package.json")"
    release_label="${RELEASE_TAG:-$upstream_version}"
    portable_dirname="$(portable_release_basename "$release_version")"
    portable_filename="$(portable_release_filename "$release_version")"

    cat > "$output_path" <<EOF
RELEASE_TAG=$release_label
RELEASE_VERSION=$release_version
UPSTREAM_VERSION=$upstream_version
TARGET_PLATFORM=$BUILD_PLATFORM
TARGET_ARCH=$BUILD_ARCH
ELECTRON_VERSION=$ELECTRON_VERSION
PACKAGE_PRODUCT_ID=$PACKAGE_PRODUCT_ID
PORTABLE_DIRNAME=$portable_dirname
PORTABLE_ARCHIVE_NAME=$portable_filename
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SOURCE_DMG=$DMG_FILE
EOF
}

package_release() {
    local upstream_version
    local release_version
    local package_name
    local package_dir
    local archive_path
    local local_electron_dir="$SCRIPT_DIR/node_modules/electron"

    upstream_version="$(node -e 'console.log(require(process.argv[1]).version)' "$BUILD_DIR/package.json")"
    release_version="$(resolve_release_version "$upstream_version")"
    package_name="$(portable_release_basename "$release_version")"
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
        CI=true npm install --production --no-audit --no-fund --loglevel=error
    )

    # npm install may omit the downloaded Electron runtime payload even when
    # the electron package itself is present. Ensure the portable bundle
    # remains self-contained by copying the local runtime payload in.
    if [ -d "$local_electron_dir/dist" ]; then
        mkdir -p "$package_dir/node_modules/electron"
        rm -rf "$package_dir/node_modules/electron/dist"
        cp -a "$local_electron_dir/dist" "$package_dir/node_modules/electron/"
        if [ -f "$local_electron_dir/path.txt" ]; then
            cp "$local_electron_dir/path.txt" "$package_dir/node_modules/electron/"
        fi
    fi

    if [ -f "$SCRIPT_DIR/codex-icon.png" ]; then
        cp "$SCRIPT_DIR/codex-icon.png" "$package_dir/"
    else
        cp "$SCRIPT_DIR/electron_512x512x32.png" "$package_dir/codex-icon.png"
    fi

    if [ -d "$ARTIFACTS_DIR/icons" ]; then
        cp -a "$ARTIFACTS_DIR/icons" "$package_dir/"
    fi

    write_build_metadata "$package_dir/build-metadata.env" "$release_version"

    tar -C "$ARTIFACTS_DIR" -czf "$archive_path" "$package_name"
    (
        cd "$ARTIFACTS_DIR"
        sha256sum "$(basename "$archive_path")" > "$(basename "$archive_path").sha256"
    )

    log "Portable artifact created: $archive_path"
}

install_desktop_entry() {
    local applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local icons_base_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
    local desktop_file="$applications_dir/codex-desktop.desktop"
    local fallback_icon_path="$SCRIPT_DIR/codex-icon.png"
    local size=""

    mkdir -p "$applications_dir"

    if [ ! -f "$fallback_icon_path" ]; then
        fallback_icon_path="$SCRIPT_DIR/electron_512x512x32.png"
    fi

    if [ -d "$ARTIFACTS_DIR/icons/hicolor" ]; then
        for size in 16 24 32 48 64 128 256 512; do
            local source_icon="$ARTIFACTS_DIR/icons/hicolor/${size}x${size}/apps/${APP_DESKTOP_ID}.png"
            local target_icon_dir="$icons_base_dir/${size}x${size}/apps"
            if [ -f "$source_icon" ]; then
                mkdir -p "$target_icon_dir"
                cp "$source_icon" "$target_icon_dir/${APP_DESKTOP_ID}.png"
            fi
        done
    elif [ -f "$fallback_icon_path" ]; then
        mkdir -p "$icons_base_dir/512x512/apps"
        cp "$fallback_icon_path" "$icons_base_dir/512x512/apps/${APP_DESKTOP_ID}.png"
    fi

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=$APP_DISPLAY_NAME
Comment=OpenAI Codex Desktop (Linux Port)
Exec=$SCRIPT_DIR/start.sh
Icon=$APP_DESKTOP_ID
Type=Application
Categories=Development;IDE;
Terminal=false
StartupWMClass=$APP_STARTUP_WM_CLASS
EOF

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t "$icons_base_dir" >/dev/null 2>&1 || true
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
    fi

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
    apply_packaged_skill_overrides
    apply_linux_desktop_identity
    rebuild_native_modules
    patch_main_js
    extract_icon

    mkdir -p "$ARTIFACTS_DIR"
    generate_icon_set
    local _upstream_ver
    _upstream_ver="$(node -e 'console.log(require(process.argv[1]).version)' "$BUILD_DIR/package.json")"
    write_build_metadata "$ARTIFACTS_DIR/build-metadata.env" "$(resolve_release_version "$_upstream_ver")"

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
