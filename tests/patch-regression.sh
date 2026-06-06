#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/codex-linux-build/dist"

err() {
    printf '[REGRESSION] FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[REGRESSION] PASS: %s\n' "$1"
}

[ -d "$DIST_DIR/.vite/build" ] || err "dist not found; run pnpm run build first"

main_bundle="$(find "$DIST_DIR/.vite/build" -maxdepth 1 -name 'main-*.js' ! -name '*.map' -type f | head -n 1)"
preload_js="$DIST_DIR/.vite/build/preload.js"
drop_handler_bundle="$(find "$DIST_DIR/.vite/build" -maxdepth 1 -name 'workspace-root-drop-handler-*.js' ! -name '*.map' -type f | head -n 1)"
if [ -z "$drop_handler_bundle" ] || [ ! -f "$drop_handler_bundle" ]; then
    drop_handler_bundle="$(find "$DIST_DIR/.vite/build" -maxdepth 1 -name '*.js' ! -name '*.map' -type f -exec grep -l 'sparkle.node' {} + | head -n 1)"
fi

# 1. Main Bundle: Opaque background branch for Linux
grep -Eq '===`linux`&&![A-Za-z_$][A-Za-z0-9_$]*\([A-Za-z_$][A-Za-z0-9_$]*\)\?\{backgroundColor:[A-Za-z_$][A-Za-z0-9_$]*\?[A-Za-z_$][A-Za-z0-9_$]*:[A-Za-z_$][A-Za-z0-9_$]*,backgroundMaterial:null\}' "$main_bundle" \
    || err "Linux dark/light opaque background branch not found in main bundle"
pass "Linux dark/light opaque background branch present in main bundle"

# 2. Main Bundle: File manager Linux entry
grep -Fq 'linux:{label:`File Manager`' "$main_bundle" || err "Linux file manager entry not found in main bundle"
pass "Linux file manager entry present in main bundle"

# 3. Main Bundle: ApplicationMenu stays alive for in-app menu buttons, while
# the duplicate native Electron menubar is hidden on Linux windows.
if grep -Eq 'process\.platform===`linux`\?\([A-Za-z_$][\w$]*\.Menu\.setApplicationMenu\(null\)' "$main_bundle"; then
    err "Linux app-menu nullification patch is still present in main bundle"
fi
if grep -Fq 'process.platform===`win32`||process.platform===`linux`' "$main_bundle"; then
    err "Linux removeMenu patch is still present in main bundle"
fi
grep -Eq 'process\.platform===`linux`&&[A-Za-z_$][\w$]*\.setMenuBarVisibility\(!1\),process\.platform===`win32`&&[A-Za-z_$][\w$]*\.removeMenu\(\)' "$main_bundle" \
    || err "Linux native Electron menubar hide patch not found in main bundle"
grep -Eq '\.Menu\.setApplicationMenu\([A-Za-z_$][A-Za-z0-9_$]*\),process\.platform===`linux`&&[A-Za-z_$][A-Za-z0-9_$]*\.BrowserWindow\.getAllWindows\(\)\.forEach\([A-Za-z_$][A-Za-z0-9_$]*=>\{[A-Za-z_$][A-Za-z0-9_$]*\.isDestroyed\(\)\|\|[A-Za-z_$][A-Za-z0-9_$]*\.setMenuBarVisibility\(!1\)\}\)' "$main_bundle" \
    || err "Linux application-menu refresh visibility patch not found in main bundle"
grep -Fq 'Menu.getApplicationMenu()?.getMenuItemById' "$main_bundle" \
    || err "In-app application-menu popup path not found in main bundle"
pass "Linux ApplicationMenu is preserved while native Electron menubar is hidden in main bundle"

# 4. Main Bundle: setBadgeCount guard
grep -Eq '[A-Za-z_$][\w$]*\.app\.setBadgeCount\?\.' "$main_bundle" || err "setBadgeCount guard patch not found in main bundle"
pass "setBadgeCount guard patch present in main bundle"

# 5. Preload JS: file:// drag-and-drop workspace support
if [ -f "$preload_js" ]; then
    grep -Fq 'require(`node:url`).fileURLToPath(p)' "$preload_js" || err "Drag-and-drop file:// URL to POSIX path patch not found in preload.js"
    pass "Drag-and-drop file:// URL to POSIX path patch present in preload.js"
else
    err "preload.js not found in build directory"
fi

# 6. Drop Handler Bundle: Sparkle auto-updater disabled on Linux
if [ -n "$drop_handler_bundle" ] && [ -f "$drop_handler_bundle" ]; then
    grep -Eq "process\.platform\s*===\s*'linux'\s*\?\s*null" "$drop_handler_bundle" \
        || err "Sparkle sparkle.node load bypass patch not found in drop handler bundle"
    pass "Sparkle sparkle.node load bypass patch present in drop handler bundle"

    grep -Eq 'async\s+checkForUpdates\(\)\s*\{\s*if\s*\(process\.platform===`linux`\)\s*return' "$drop_handler_bundle" \
        || err "Sparkle checkForUpdates bypass patch not found in drop handler bundle"
    pass "Sparkle checkForUpdates bypass patch present in drop handler bundle"

    grep -Eq 'async\s+installUpdatesIfAvailable\(\)\s*\{\s*if\s*\(process\.platform===`linux`\)\s*return' "$drop_handler_bundle" \
        || err "Sparkle installUpdatesIfAvailable bypass patch not found in drop handler bundle"
    pass "Sparkle installUpdatesIfAvailable bypass patch present in drop handler bundle"

    grep -Eq 'async\s+checkForUpdatesInBackground\(\)\s*\{\s*if\s*\(process\.platform===`linux`\)\s*return' "$drop_handler_bundle" \
        || err "Sparkle checkForUpdatesInBackground bypass patch not found in drop handler bundle"
    pass "Sparkle checkForUpdatesInBackground bypass patch present in drop handler bundle"
else
    err "Drop handler bundle containing Sparkle code not found"
fi

printf '[REGRESSION] All regression checks passed successfully\n'
exit 0
