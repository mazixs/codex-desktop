#!/usr/bin/env bash
# ============================================================================
# Codex Desktop for Linux — Update Checker
#
# Checks if a newer upstream DMG is available by comparing HTTP HEAD metadata
# (ETag + Last-Modified) against locally stored values. Triggers a rebuild
# when the upstream changes or when LINUX_PATCH_VERSION is bumped.
#
# Inspired by jpenilla/codex-desktop-linux's freshness check.
# ============================================================================
set -eo pipefail

# Resolve SCRIPT_DIR whether run directly or sourced
if [ -n "${BASH_SOURCE[0]+x}" ] && [ -n "${BASH_SOURCE[0]}" ]; then
    _UPDATE_SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    _UPDATE_SCRIPT_PATH="${0}"
fi
SCRIPT_DIR="$(cd "$(dirname "$_UPDATE_SCRIPT_PATH")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop"
METADATA_FILE="$CACHE_DIR/update-metadata.json"
DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
CODEX_GET_STARTED_URL="https://chatgpt.com/features/codex-get-started"

# Bump this to force a rebuild even without upstream changes
LINUX_PATCH_VERSION=1

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log()  { printf '%s[update]%s %s\n' "$GREEN"  "$NC" "$1" >&2; }
warn() { printf '%s[update]%s %s\n' "$YELLOW" "$NC" "$1" >&2; }
err()  { printf '%s[update]%s %s\n' "$RED"    "$NC" "$1" >&2; }

# ---- Resolve the latest DMG URL ----
# Scrapes the OpenAI "get started" page for the current download URL.
# Falls back to the hardcoded default if scraping fails.
resolve_dmg_url() {
    if command -v curl >/dev/null 2>&1; then
        local html
        html="$(curl -sL --max-time 10 --connect-timeout 5 "$CODEX_GET_STARTED_URL" 2>/dev/null)" || true
        if [ -n "$html" ]; then
            local scraped_url
            scraped_url="$(printf '%s' "$html" | grep -oP 'https://persistent\.oaistatic\.com/[^"'"'"'\\\s>]*Codex\.dmg' | head -1)" || true
            if [ -n "$scraped_url" ]; then
                printf '%s' "$scraped_url"
                return 0
            fi
        fi
    fi
    printf '%s' "$DMG_URL"
}

# ---- Get remote ETag + Last-Modified via HEAD request ----
get_remote_metadata() {
    local url="$1"
    local headers
    headers="$(curl -sI -L --max-time 10 --connect-timeout 5 "$url" 2>/dev/null)" || true

    local etag last_modified
    etag="$(printf '%s' "$headers" | grep -i '^etag:' | tail -1 | sed 's/^[^:]*: *//;s/\r$//')" || true
    last_modified="$(printf '%s' "$headers" | grep -i '^last-modified:' | tail -1 | sed 's/^[^:]*: *//;s/\r$//')" || true

    printf '%s\n%s' "$etag" "$last_modified"
}

# ---- Read local metadata JSON ----
# Uses python3 (already a build dep) to parse JSON — no jq dependency.
read_local_field() {
    local field="$1"
    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi
    python3 -c "
import json, sys
try:
    d = json.load(open('$METADATA_FILE'))
    v = d.get('$field', '')
    print(v if v is not None else '')
except:
    sys.exit(1)
" 2>/dev/null
}

# ---- Write local metadata JSON ----
write_metadata() {
    local url="$1" etag="$2" last_modified="$3" patch_version="$4"
    mkdir -p "$CACHE_DIR"
    python3 -c "
import json
d = {
    'dmg_url': $(printf '%s' "$url" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"),
    'etag': $(printf '%s' "$etag" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"),
    'last_modified': $(printf '%s' "$last_modified" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"),
    'linux_patch_version': $patch_version,
    'checked_at': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()
}
with open('$METADATA_FILE', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
}

# ---- Check if update is needed ----
# Returns 0 (true) if update needed, 1 (false) if current.
check_update() {
    local resolved_url
    resolved_url="$(resolve_dmg_url)"
    log "Checking for upstream updates..."

    local remote_meta etag last_modified
    remote_meta="$(get_remote_metadata "$resolved_url")"
    etag="$(printf '%s' "$remote_meta" | head -1)"
    last_modified="$(printf '%s' "$remote_meta" | tail -1)"

    # If we can't reach the server, skip the check
    if [ -z "$etag" ] && [ -z "$last_modified" ]; then
        warn "Cannot reach upstream — skipping update check"
        return 1
    fi

    # No local metadata = first run
    if [ ! -f "$METADATA_FILE" ]; then
        log "No local metadata found — update needed"
        printf '%s\n%s\n%s' "$resolved_url" "$etag" "$last_modified"
        return 0
    fi

    local local_url local_etag local_last_modified local_patch
    local_url="$(read_local_field dmg_url)" || true
    local_etag="$(read_local_field etag)" || true
    local_last_modified="$(read_local_field last_modified)" || true
    local_patch="$(read_local_field linux_patch_version)" || true

    # Check if our patch version bumped (forced rebuild)
    if [ "${local_patch:-0}" != "$LINUX_PATCH_VERSION" ]; then
        log "Patch version bumped ($local_patch -> $LINUX_PATCH_VERSION) — rebuild needed"
        printf '%s\n%s\n%s' "$resolved_url" "$etag" "$last_modified"
        return 0
    fi

    # Check if URL changed
    if [ "$local_url" != "$resolved_url" ]; then
        log "DMG URL changed — update available"
        printf '%s\n%s\n%s' "$resolved_url" "$etag" "$last_modified"
        return 0
    fi

    # Check ETag
    if [ -n "$etag" ] && [ "$local_etag" != "$etag" ]; then
        log "ETag changed — update available"
        printf '%s\n%s\n%s' "$resolved_url" "$etag" "$last_modified"
        return 0
    fi

    # Check Last-Modified
    if [ -n "$last_modified" ] && [ "$local_last_modified" != "$last_modified" ]; then
        log "Last-Modified changed — update available"
        printf '%s\n%s\n%s' "$resolved_url" "$etag" "$last_modified"
        return 0
    fi

    log "Up to date"
    return 1
}

# ---- Main entry point ----
# When sourced by start.sh, call check_update and act on the result.
# When run directly, just report status.
if [ -z "${_SOURCED_BY_START_SH:-}" ]; then
    update_info="$(check_update)" && {
        resolved_url="$(printf '%s' "$update_info" | sed -n '1p')"
        etag="$(printf '%s' "$update_info" | sed -n '2p')"
        last_modified="$(printf '%s' "$update_info" | sed -n '3p')"

        echo ""
        log "Update available! Run the build to apply:"
        echo "  cd $SCRIPT_DIR && ./build.sh --clean"
        echo ""
        log "After building, update metadata with:"
        echo "  $0 --mark-current"
        exit 0
    } || {
        exit 0
    }
fi
