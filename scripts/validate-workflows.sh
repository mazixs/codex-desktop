#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if ! command -v actionlint >/dev/null 2>&1; then
    printf '[workflow-validate][error] actionlint is not installed or not in PATH\n' >&2
    exit 1
fi

if ! command -v shellcheck >/dev/null 2>&1; then
    printf '[workflow-validate][error] shellcheck is not installed or not in PATH\n' >&2
    exit 1
fi

cd "$PROJECT_ROOT"
actionlint -color -shellcheck="$(command -v shellcheck)"
