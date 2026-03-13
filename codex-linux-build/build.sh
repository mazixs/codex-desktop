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
ELECTRON_VERSION="${ELECTRON_VERSION:-40.0.0}"
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
    local deeplinks_bundle=""
    local old_text=""
    local new_text=""

    ensure_main_entry_exists "$BUILD_DIR/package.json" "$BUILD_DIR"

    # Find the hashed main bundle (main-*.js)
    main_bundle="$(find "$BUILD_DIR/.vite/build" -maxdepth 1 -name 'main-*.js' ! -name '*.map' -type f | head -n 1)"
    if [ -z "$main_bundle" ] || [ ! -f "$main_bundle" ]; then
        err "Main bundle not found in $BUILD_DIR/.vite/build/"
        exit 1
    fi

    # Find the hashed deeplinks bundle (deeplinks-*.js)
    deeplinks_bundle="$(find "$BUILD_DIR/.vite/build" -maxdepth 1 -name 'deeplinks-*.js' ! -name '*.map' -type f | head -n 1)"
    if [ -z "$deeplinks_bundle" ] || [ ! -f "$deeplinks_bundle" ]; then
        err "Deeplinks bundle not found in $BUILD_DIR/.vite/build/"
        exit 1
    fi

    log "Patching Electron main process bundles..."
    log "  main bundle: $(basename "$main_bundle")"
    log "  deeplinks bundle: $(basename "$deeplinks_bundle")"
    cp "$main_bundle" "$main_bundle.bak"
    cp "$deeplinks_bundle" "$deeplinks_bundle.bak"

    # --- Disable macOS/Windows-specific window appearance properties ---
    # These cause broken rendering on Linux (transparent windows, missing backgrounds)

    # Hf=#00000000 is a fully-transparent background used by macOS vibrancy;
    # on Linux without vibrancy the window becomes invisible. Replace with opaque dark bg.
    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'Hf=`#00000000`' 'Hf=`#1e1e1e`'

    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'transparent:!0' 'transparent:!1'
    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'vibrancy:`menu`' 'vibrancy:null'
    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'visualEffectState:`active`' 'visualEffectState:null'
    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'backgroundMaterial:`mica`' 'backgroundMaterial:null'
    # shellcheck disable=SC2016
    replace_literal "$main_bundle" 'backgroundMaterial:`none`' 'backgroundMaterial:null'

    # --- Add Linux file manager support ---
    # The upstream fileManager target only defines darwin and win32 platforms.
    # On Linux the "Open folder" button in Skills silently fails because
    # there is no linux entry, so the target is never registered.
    # Add linux support using xdg-open.
    # shellcheck disable=SC2016
    old_text='const Xa=ea({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>pa(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Za,args:e=>pa(e),open:async({path:e})=>Qa(e)}})'
    # shellcheck disable=SC2016
    new_text='const Xa=ea({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>pa(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:Za,args:e=>pa(e),open:async({path:e})=>Qa(e)},linux:{label:`File Manager`,detect:()=>B(`xdg-open`),args:e=>[e],open:async({path:e})=>{let n=e;try{(0,a.statSync)(n).isFile()&&(n=(0,r.dirname)(n))}catch{}let i=await t.shell.openPath(n);if(i)throw Error(i)}}})'
    replace_literal "$main_bundle" "$old_text" "$new_text"

    # --- Skills path function (yc) in main bundle ---
    # Makes the skills directory discoverable with existence checks and fallback paths
    # shellcheck disable=SC2016
    old_text='function yc(n){let r=e.qt(n),i=t.app.getAppPath();if(t.app.isPackaged)return r.join(i,`skills`);let o=r.join(i,`assets`,`skills`);if((0,a.existsSync)(o))return o;let s=r.join(i,`..`,`assets`,`skills`);return(0,a.existsSync)(s)?s:null}'
    # shellcheck disable=SC2016
    new_text='function yc(n){let r=e.qt(n),i=t.app.getAppPath(),o=r.join(i,`skills`);if((0,a.existsSync)(o))return o;if(t.app.isPackaged)return o;let s=r.join(i,`assets`,`skills`);if((0,a.existsSync)(s))return s;let c=r.join(i,`..`,`skills`);if((0,a.existsSync)(c))return c;let l=r.join(i,`..`,`assets`,`skills`);return(0,a.existsSync)(l)?l:null}'
    replace_literal "$main_bundle" "$old_text" "$new_text" 1

    # --- Patches in deeplinks bundle ---

    # Mk: recommended skills loader — add bundled skill override support
    # shellcheck disable=SC2016
    old_text='async function Mk({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,hostConfig:r}){let i=jp(r)?r.terminal_command.join(` `):void 0,a=jp(r)?await __(r):g_({preferWsl:t,hostConfig:r}),o=b_(r),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=Qk(o),u=$k(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:o.resolve(n),h=m?u.map(e=>o.join(m,e)):null,g=m?o.join(m,l):null,_=await Xk(p,r),v=e||!_||Jk(_),y=await Yk(o.join(c,`.git`),r),b=await Yk(f,r),x=g?await Yk(g,r):!1;try{if(!e&&!y&&!b&&x){let e=await Nk({repoRoot:m??c,recommendedRoots:h??d,path:o,hostConfig:r}),t=Date.now();return await Zk(p,{fetchedAt:t,skills:e},r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;v&&(y||!b)&&(await Uk({repoRoot:c,vendorRoot:s,hostConfig:r}),await Wk(c,r),await Gk(c,u,r),t=!0);let n=await Nk({repoRoot:c,recommendedRoots:d,path:o,hostConfig:r}),i=t?Date.now():_?.fetchedAt??Date.now();return await Zk(p,{fetchedAt:i,skills:n},r),{skills:n,fetchedAt:i,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!b&&!y&&x&&m?m:c;return Tk().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),_?{skills:_.skills,fetchedAt:_.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:[],fetchedAt:null,source:`cache`,repoRoot:n,error:t}}}'
    # shellcheck disable=SC2016
    new_text='async function Mk({refresh:e=!1,preferWsl:t=!1,bundledRepoRoot:n=null,hostConfig:r}){let i=jp(r)?r.terminal_command.join(` `):void 0,a=jp(r)?await __(r):g_({preferWsl:t,hostConfig:r}),o=b_(r),s=o.join(a,`vendor_imports`),c=o.join(s,`skills`),l=Qk(o),u=$k(o),d=u.map(e=>o.join(c,e)),f=o.join(c,l),p=o.join(s,`skills-curated-cache.json`),m=i||!n?null:o.resolve(n),h=m?u.map(e=>o.join(m,e)):[],g=m?o.join(m,l):null,_=await Xk(p,r),v=e||!_||Jk(_),y=await Yk(o.join(c,`.git`),r),b=await Yk(f,r),x=g?await Yk(g,r):!1,S=async()=>x&&m?Nk({repoRoot:m,recommendedRoots:h,path:o,hostConfig:r,sourceTag:`bundled-override`}):[];try{if(!e&&!y&&!b&&x){let e=logBundledSkillOverrides(await S(),`bundled`),t=Date.now();return await Zk(p,{fetchedAt:t,skills:e},r),{skills:e,fetchedAt:t,source:`bundled`,repoRoot:m??null,error:null}}let t=!1;v&&(y||!b)&&(await Uk({repoRoot:c,vendorRoot:s,hostConfig:r}),await Wk(c,r),await Gk(c,u,r),t=!0);let n=await Nk({repoRoot:c,recommendedRoots:d,path:o,hostConfig:r,sourceTag:t?`git`:`cache`}),i=logBundledSkillOverrides(mergeRecommendedSkillLists(await S(),n),t?`git`:`cache`),a=t?Date.now():_?.fetchedAt??Date.now();return await Zk(p,{fetchedAt:a,skills:i},r),{skills:i,fetchedAt:a,source:t?`git`:`cache`,repoRoot:c,error:null}}catch(e){let t=e instanceof Error?e.message:String(e),n=!b&&!y&&x&&m?m:c,i=await S().catch(()=>[]);return Tk().warning(`Failed to load recommended skills`,{safe:{},sensitive:{error:e}}),_?{skills:logBundledSkillOverrides(mergeRecommendedSkillLists(i,_.skills),`cache`),fetchedAt:_.fetchedAt,source:`cache`,repoRoot:n,error:t}:{skills:i,fetchedAt:null,source:i.length>0?`bundled`:`cache`,repoRoot:n,error:t}}}'
    replace_literal "$deeplinks_bundle" "$old_text" "$new_text" 1

    # Nk: skill enumerator — add sourceTag + prepend helper functions
    # shellcheck disable=SC2016
    old_text='async function Nk({repoRoot:e,recommendedRoots:t,path:n,hostConfig:r}){let i=new Map,a=await Promise.all(t.map(async t=>Pk({recommendedRoot:t,repoRoot:e,path:n,hostConfig:r})));for(let e of a)for(let t of e)i.has(t.id)||i.set(t.id,t);return Array.from(i.values()).sort((e,t)=>e.name.localeCompare(t.name))}'
    # shellcheck disable=SC2016
    new_text='function skillIconMimeType(e){switch(e){case `.svg`:return `image/svg+xml`;case `.png`:return `image/png`;case `.jpg`:case `.jpeg`:return `image/jpeg`;case `.webp`:return `image/webp`;default:return null}}async function normalizeSkillIconUrl(e,t,n,r){if(!e)return null;if(/^https?:\/\//i.test(e)||e.startsWith(`data:`))return e;let i=n.isAbsolute(e)?e:n.resolve(t,e),a=skillIconMimeType(n.extname(i).toLowerCase());if(!a)return i;try{let e=await F.readFileBase64(i,r);return`data:${a};base64,${e.toString(`base64`)}`}catch{return i}}function mergeRecommendedSkillLists(e,t){let n=new Map;for(let r of[...e,...t])n.has(r.id)||n.set(r.id,r);return Array.from(n.values()).sort((e,t)=>e.name.localeCompare(t.name))}function logBundledSkillOverrides(e,t){let n=e.filter(e=>e.skillSource===`bundled-override`).map(e=>e.id);return n.length>0&&Tk().info(`Using bundled skill overrides`,{safe:{skillIds:n,baseSource:t},sensitive:{}}),e}async function Nk({repoRoot:e,recommendedRoots:t,path:n,hostConfig:r,sourceTag:i=null}){let a=new Map,o=await Promise.all(t.map(async t=>Pk({recommendedRoot:t,repoRoot:e,path:n,hostConfig:r,sourceTag:i})));for(let e of o)for(let t of e)a.has(t.id)||a.set(t.id,t);return Array.from(a.values()).sort((e,t)=>e.name.localeCompare(t.name))}'
    replace_literal "$deeplinks_bundle" "$old_text" "$new_text" 1

    # Pk: individual skill loader — add sourceTag, icon normalization
    # shellcheck disable=SC2016
    old_text='async function Pk({recommendedRoot:e,repoRoot:t,path:n,hostConfig:r}){if(!await Yk(e,r))return[];let i=await F.readdir(e,r);return(await Promise.all(i.map(async i=>{if(i.startsWith(`.`))return null;let a=n.join(e,i),o=(await F.stat(a,r)).isDirectory(),s=o?n.join(a,`SKILL.md`):a;if(!await Yk(s,r))return null;let c=Lk(await F.readFile(s,r)),l=await zk({path:n,hostConfig:r,skillRoot:a}),u=o?i:n.parse(i).name,d=c.description??c.shortDescription??u,f=await Vk({path:n,hostConfig:r,skillRoot:a,skillId:u,iconSmall:c.iconSmall??l.iconSmall??null,iconLarge:c.iconLarge??l.iconLarge??null,isDirectory:o}),p=o?qk(n,t,a):qk(n,t,s);return{id:u,name:c.name??u,description:d,shortDescription:c.shortDescription??l.shortDescription,iconSmall:f.iconSmall,iconLarge:f.iconLarge,repoPath:p}}))).filter(e=>e!=null)}'
    # shellcheck disable=SC2016
    new_text='async function Pk({recommendedRoot:e,repoRoot:t,path:n,hostConfig:r,sourceTag:i=null}){if(!await Yk(e,r))return[];let a=await F.readdir(e,r);return(await Promise.all(a.map(async a=>{if(a.startsWith(`.`))return null;let o=n.join(e,a),s=(await F.stat(o,r)).isDirectory(),c=s?n.join(o,`SKILL.md`):o;if(!await Yk(c,r))return null;let l=Lk(await F.readFile(c,r)),u=await zk({path:n,hostConfig:r,skillRoot:o}),d=s?a:n.parse(a).name,f=l.description??l.shortDescription??d,p=await Vk({path:n,hostConfig:r,skillRoot:o,skillId:d,iconSmall:l.iconSmall??u.iconSmall??null,iconLarge:l.iconLarge??u.iconLarge??null,isDirectory:s}),m=s?qk(n,t,o):qk(n,t,c);return{id:d,name:l.name??d,description:f,shortDescription:l.shortDescription??u.shortDescription,iconSmall:await normalizeSkillIconUrl(p.iconSmall,o,n,r),iconLarge:await normalizeSkillIconUrl(p.iconLarge,o,n,r),repoPath:m,skillSource:i}}))).filter(e=>e!=null)}'
    replace_literal "$deeplinks_bundle" "$old_text" "$new_text" 1

    # tA: skill resolver — prioritize bundled skills over remote
    # shellcheck disable=SC2016
    old_text='async function tA({repoRoot:e,bundledRepoRoot:t,repoPath:n,hostConfig:r}){let i=nA(e,n,r);if(await rA(i,r))return i;if(!t)return null;let a=nA(t,n,r);return await rA(a,r)?a:null}'
    # shellcheck disable=SC2016
    new_text='async function tA({repoRoot:e,bundledRepoRoot:t,repoPath:n,hostConfig:r}){if(t){let i=nA(t,n,r);if(await rA(i,r))return i}let a=nA(e,n,r);return await rA(a,r)?a:null}'
    replace_literal "$deeplinks_bundle" "$old_text" "$new_text" 1

    # Verify patched bundles parse correctly
    node --check "$main_bundle"
    node --check "$deeplinks_bundle"

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
