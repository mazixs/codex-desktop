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

# Opaque background: Linux branch exists
grep -Fq '===`linux`&&!' "$main_bundle" || err "Linux opaque background branch not found in main bundle"
pass "Linux opaque background branch present"

# File manager: Linux entry exists
grep -Fq 'linux:{label:`File Manager`' "$main_bundle" || err "Linux file manager entry not found"
pass "Linux file manager entry present"

# App menu: Linux null-menu branch exists
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
else
    pass "Browser Use plugin resources not present (optional)"
fi

printf '[SMOKE] All smoke tests passed\n'
