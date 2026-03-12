#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGE_JSON="$PROJECT_ROOT/codex-linux-build/package.json"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '[pnpm-bootstrap][error] Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

require_command node
require_command corepack

PNPM_VERSION="$(node -e 'const manifest=require(process.argv[1]); const manager=manifest.packageManager || ""; const match=manager.match(/^pnpm@(.+)$/); if (!match) { process.exit(1); } console.log(match[1]);' "$PACKAGE_JSON")"

if [ -z "$PNPM_VERSION" ]; then
    printf '[pnpm-bootstrap][error] Could not resolve pnpm version from %s\n' "$PACKAGE_JSON" >&2
    exit 1
fi

printf '[pnpm-bootstrap] Activating pnpm@%s via Corepack\n' "$PNPM_VERSION"
corepack enable
corepack prepare "pnpm@${PNPM_VERSION}" --activate

ACTUAL_PNPM_VERSION="$(pnpm --version)"
if [ "$ACTUAL_PNPM_VERSION" != "$PNPM_VERSION" ]; then
    printf '[pnpm-bootstrap][error] Expected pnpm %s but activated %s\n' "$PNPM_VERSION" "$ACTUAL_PNPM_VERSION" >&2
    exit 1
fi

printf '[pnpm-bootstrap] pnpm %s ready\n' "$ACTUAL_PNPM_VERSION"
