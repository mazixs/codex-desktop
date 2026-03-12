#!/usr/bin/env bash
set -euo pipefail

VERSION="${ACTIONLINT_VERSION:-1.7.8}"
INSTALL_DIR="${ACTIONLINT_INSTALL_DIR:-/tmp/actionlint/bin}"
ARCHIVE_BASENAME="actionlint_${VERSION#v}_linux_amd64.tar.gz"
ARCHIVE_URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION#v}/${ARCHIVE_BASENAME}"
CHECKSUM_BASENAME="actionlint_${VERSION#v}_checksums.txt"
CHECKSUM_URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION#v}/${CHECKSUM_BASENAME}"
WORK_DIR=""

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '[actionlint-install][error] Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

for cmd in curl sha256sum tar; do
    require_command "$cmd"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/actionlint.XXXXXX")"
mkdir -p "$INSTALL_DIR"

printf '[actionlint-install] Downloading actionlint %s\n' "$VERSION"
curl --fail --location --silent --show-error "$ARCHIVE_URL" -o "$WORK_DIR/$ARCHIVE_BASENAME"
curl --fail --location --silent --show-error "$CHECKSUM_URL" -o "$WORK_DIR/$CHECKSUM_BASENAME"

EXPECTED_SHA="$(awk -v archive="$ARCHIVE_BASENAME" '$2 == archive {print $1}' "$WORK_DIR/$CHECKSUM_BASENAME")"
if [ -z "$EXPECTED_SHA" ]; then
    printf '[actionlint-install][error] Failed to resolve checksum for %s\n' "$ARCHIVE_BASENAME" >&2
    exit 1
fi

ACTUAL_SHA="$(sha256sum "$WORK_DIR/$ARCHIVE_BASENAME" | awk '{print $1}')"
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    printf '[actionlint-install][error] Checksum mismatch for %s\n' "$ARCHIVE_BASENAME" >&2
    exit 1
fi

tar -xzf "$WORK_DIR/$ARCHIVE_BASENAME" -C "$WORK_DIR"
install -m755 "$WORK_DIR/actionlint" "$INSTALL_DIR/actionlint"
"$INSTALL_DIR/actionlint" -version
