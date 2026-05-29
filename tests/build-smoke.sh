#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/codex-linux-build/dist"

err() {
    printf '[SMOKE] FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[SMOKE] PASS: %s\n' "$1"
}

[ -d "$DIST_DIR/.vite/build" ] || err "dist not found; run ./build.sh first"

main_bundle="$(find "$DIST_DIR/.vite/build" -maxdepth 1 -name 'main-*.js' ! -name '*.map' -type f | head -n 1)"
comment_preload="$DIST_DIR/.vite/build/comment-preload.js"
browser_client=""
for candidate in "$DIST_DIR"/plugins/openai-bundled/plugins/{browser,browser-use}/scripts/browser-client.mjs; do
    if [ -f "$candidate" ]; then
        browser_client="$candidate"
        break
    fi
done
browser_plugin_json=""
for candidate in "$DIST_DIR"/plugins/openai-bundled/plugins/{browser,browser-use}/.codex-plugin/plugin.json; do
    if [ -f "$candidate" ]; then
        browser_plugin_json="$candidate"
        break
    fi
done
chrome_browser_client="$DIST_DIR/plugins/openai-bundled/plugins/chrome/scripts/browser-client.mjs"
chrome_plugin_json="$DIST_DIR/plugins/openai-bundled/plugins/chrome/.codex-plugin/plugin.json"

# Opaque background: Linux branch exists
# shellcheck disable=SC2016
grep -Eq '===`linux`&&![A-Za-z_$][A-Za-z0-9_$]*\([A-Za-z_$][A-Za-z0-9_$]*\)\?\{backgroundColor:[A-Za-z_$][A-Za-z0-9_$]*\?[A-Za-z_$][A-Za-z0-9_$]*:[A-Za-z_$][A-Za-z0-9_$]*,backgroundMaterial:null\}' "$main_bundle" \
    || err "Linux dark/light opaque background branch not found"
pass "Linux dark/light opaque background branch present"

# File manager: Linux entry exists
# shellcheck disable=SC2016
grep -Fq 'linux:{label:`File Manager`' "$main_bundle" || err "Linux file manager entry not found"
pass "Linux file manager entry present"

# App menu: Linux null-menu branch exists
# shellcheck disable=SC2016
grep -Fq 'process.platform===`linux`?(n.Menu.setApplicationMenu(null)' "$main_bundle" || err "Linux app-menu patch not found"
pass "Linux app-menu patch present"

# Comment-preload: stored-anchor screenshot path
if [ -f "$comment_preload" ]; then
    if grep -Eq '(ye=Sd\(F\.anchor\)|De=al\(me\.anchor\),ke=void 0)' "$comment_preload"; then
        pass "Comment-preload stored-anchor patch present"
    else
        pass "Comment-preload stored-anchor patch not present (optional)"
    fi

    if grep -Eq '(ge=fe\?de:|be=\(ge\?he:)' "$comment_preload"; then
        pass "Comment-preload marker-filter patch present"
    else
        pass "Comment-preload marker-filter patch not present (optional)"
    fi
else
    pass "Comment-preload not present (optional)"
fi

# Browser Use plugin resources
if [ -d "$DIST_DIR/plugins/openai-bundled" ]; then
    [ -f "$DIST_DIR/plugins/openai-bundled/.agents/plugins/marketplace.json" ] || err "Browser Use marketplace.json missing"
    pass "Browser Use plugin resources present"

    if [ -d "$DIST_DIR/plugins/openai-bundled/plugins/chrome" ]; then
        grep -Fq '"name": "chrome"' "$DIST_DIR/plugins/openai-bundled/.agents/plugins/marketplace.json" \
            || err "Chrome plugin marketplace entry missing"
        pass "Chrome plugin marketplace entry present"
    fi

    if [ -n "$browser_plugin_json" ] && [ -f "$browser_plugin_json" ]; then
        grep -Eq '"version": "[^"]+-linux\.1"' "$browser_plugin_json" || err "Browser Use Linux patched version missing"
        pass "Browser Use Linux patched version present"
    fi
    if [ -f "$chrome_plugin_json" ]; then
        grep -Eq '"version": "[^"]+-linux\.1"' "$chrome_plugin_json" || err "Chrome Linux patched version missing"
        pass "Chrome Linux patched version present"
    fi

    if [ -n "$browser_client" ] && [ -f "$browser_client" ]; then
        grep -Fq '/aura/site_status' "$browser_client" || err "Browser Use site_status endpoint missing"
        ! grep -Fq 'url_request_source' "$browser_client" || err "Browser Use site_status request metadata params still present"
        pass "Browser Use site_status allowlist patch present"
        grep -Fq 'import.meta.__codexNativePipe' "$browser_client" \
            || err "Browser Use native pipe trust bridge patch missing"
        pass "Browser Use native pipe trust bridge patch present"

        browser_client_hash="$(sha256sum "$browser_client" | awk '{print $1}')"
        grep -Fq "\`$browser_client_hash\`" "$main_bundle" || err "Browser Use trusted client hash not updated in main bundle"
        pass "Browser Use trusted client hash updated"
    fi
    if [ -f "$chrome_browser_client" ]; then
        grep -Fq "codexLinuxChromeUserDataDirectories" "$chrome_browser_client" \
            || err "Chrome Linux profile roots patch missing"
        grep -Fq '"BraveSoftware","Brave-Browser"' "$chrome_browser_client" \
            || err "Chrome Brave profile root missing"
        grep -Fq '".config","chromium"' "$chrome_browser_client" \
            || err "Chrome Chromium profile root missing"
        grep -Fq "userDataDir:" "$chrome_browser_client" \
            || err "Chrome Linux profile metadata matching missing"
        pass "Chrome Linux profile metadata patch present"
    fi
else
    pass "Browser Use plugin resources not present (optional)"
fi

grep -Eq 'installWhenMissing:!0,name:[A-Za-z_$][A-Za-z0-9_$]*,.*isAvailable:\(\{[^}]*\}\)=>[^{}]*externalBrowserUseAllowed' "$main_bundle" \
    || err "Chrome plugin auto-install gate not found"
pass "Chrome plugin auto-install gate present"

# node_repl binary for Browser Use MCP server
if [ -f "$DIST_DIR/node_repl" ]; then
    file "$DIST_DIR/node_repl" | grep -q "ELF" || err "dist/node_repl is not a Linux ELF binary"
    pass "node_repl Linux ELF binary present"
    if command -v readelf >/dev/null 2>&1; then
        ldd_output="$(ldd --version 2>&1 || true)"
        glibc_version=""
        if echo "$ldd_output" | grep -q "GNU libc"; then
            glibc_version="$(echo "$ldd_output" | grep "GNU libc" | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
        fi
        skip_glibc_check=0
        if [ -n "$glibc_version" ]; then
            major="$(echo "$glibc_version" | cut -d. -f1)"
            minor="$(echo "$glibc_version" | cut -d. -f2)"
            if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 39 ]; }; then
                skip_glibc_check=1
            fi
        fi
        if [ "$skip_glibc_check" -eq 1 ]; then
            pass "node_repl glibc compatibility check skipped (system glibc >= 2.39)"
        else
            ! readelf -V "$DIST_DIR/node_repl" 2>/dev/null | grep -q 'Name: GLIBC_2\.39' \
                || err "node_repl still requires GLIBC_2.39"
            pass "node_repl glibc compatibility patch present"
        fi
    fi
else
    pass "node_repl not present (optional)"
fi

# node symlink for Browser Use fallback
if [ -L "$DIST_DIR/node" ]; then
    pass "node symlink present"
else
    pass "node symlink not present (optional)"
fi

printf '[SMOKE] All smoke tests passed\n'
