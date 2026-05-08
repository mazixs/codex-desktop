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
browser_client="$DIST_DIR/plugins/openai-bundled/plugins/browser-use/scripts/browser-client.mjs"
browser_plugin_json="$DIST_DIR/plugins/openai-bundled/plugins/browser-use/.codex-plugin/plugin.json"

# Opaque background: Linux branch exists
# shellcheck disable=SC2016
grep -Fq '===`linux`&&!' "$main_bundle" || err "Linux opaque background branch not found in main bundle"
pass "Linux opaque background branch present"

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
    grep -Fq 'ye=Sd(F.anchor)' "$comment_preload" || err "Comment-preload stored-anchor patch not found"
    pass "Comment-preload stored-anchor patch present"

    grep -Fq 'ge=fe?de:' "$comment_preload" || err "Comment-preload marker-filter patch not found"
    pass "Comment-preload marker-filter patch present"
else
    pass "Comment-preload not present (optional)"
fi

# Browser Use plugin resources
if [ -d "$DIST_DIR/plugins/openai-bundled" ]; then
    [ -f "$DIST_DIR/plugins/openai-bundled/.agents/plugins/marketplace.json" ] || err "Browser Use marketplace.json missing"
    pass "Browser Use plugin resources present"

    if [ -f "$browser_plugin_json" ]; then
        grep -Fq '"version": "0.1.0-alpha1-linux.1"' "$browser_plugin_json" || err "Browser Use Linux patched version missing"
        pass "Browser Use Linux patched version present"
    fi

    if [ -f "$browser_client" ]; then
        grep -Fq 'new URL(`${k7}/aura/site_status`)' "$browser_client" || err "Browser Use site_status endpoint missing"
        grep -Fq 'r.searchParams.set("site_url",n.toString()),r.toString()' "$browser_client" || err "Browser Use site_status allowlist patch missing"
        ! grep -Fq 'url_request_source' "$browser_client" || err "Browser Use site_status request metadata params still present"
        pass "Browser Use site_status allowlist patch present"

        browser_client_hash="$(sha256sum "$browser_client" | awk '{print $1}')"
        grep -Fq "\`$browser_client_hash\`" "$main_bundle" || err "Browser Use trusted client hash not updated in main bundle"
        pass "Browser Use trusted client hash updated"
    fi
else
    pass "Browser Use plugin resources not present (optional)"
fi

# node_repl binary for Browser Use MCP server
if [ -f "$DIST_DIR/node_repl" ]; then
    file "$DIST_DIR/node_repl" | grep -q "ELF" || err "dist/node_repl is not a Linux ELF binary"
    pass "node_repl Linux ELF binary present"
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
