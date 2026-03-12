#!/usr/bin/env bash

PACKAGE_PRODUCT_ID="${PACKAGE_PRODUCT_ID:-codex-desktop-native}"
PORTABLE_PLATFORM_ID="${PORTABLE_PLATFORM_ID:-linux-portable-x64}"
ARCH_PLATFORM_ID="${ARCH_PLATFORM_ID:-archlinux-x86_64}"
PORTABLE_MIN_SIZE_BYTES="${PORTABLE_MIN_SIZE_BYTES:-52428800}"

ci_log() {
    printf '[ci] %s\n' "$1"
}

ci_warn() {
    printf '[ci][warn] %s\n' "$1" >&2
}

ci_fail() {
    printf '[ci][error] %s\n' "$1" >&2
    exit 1
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        ci_fail "Required command not found: $cmd"
    fi
}

portable_release_basename() {
    local version="$1"
    printf '%s-%s-%s\n' "$PACKAGE_PRODUCT_ID" "$version" "$PORTABLE_PLATFORM_ID"
}

portable_release_filename() {
    local version="$1"
    printf '%s.tar.gz\n' "$(portable_release_basename "$version")"
}

portable_release_glob() {
    printf '%s-*-%s.tar.gz\n' "$PACKAGE_PRODUCT_ID" "$PORTABLE_PLATFORM_ID"
}

arch_release_filename() {
    local version="$1"
    printf '%s-%s-%s.pkg.tar.zst\n' "$PACKAGE_PRODUCT_ID" "$version" "$ARCH_PLATFORM_ID"
}

arch_release_glob() {
    printf '%s-*-%s.pkg.tar.zst\n' "$PACKAGE_PRODUCT_ID" "$ARCH_PLATFORM_ID"
}

require_file() {
    local file_path="$1"

    if [ ! -f "$file_path" ]; then
        ci_fail "Required file not found: $file_path"
    fi
}

require_dir() {
    local dir_path="$1"

    if [ ! -d "$dir_path" ]; then
        ci_fail "Required directory not found: $dir_path"
    fi
}

find_single_matching_file() {
    local search_dir="$1"
    local file_glob="$2"
    local label="$3"
    local matches=()

    require_dir "$search_dir"

    mapfile -t matches < <(find "$search_dir" -maxdepth 1 -type f -name "$file_glob" | sort)
    if [ "${#matches[@]}" -eq 0 ]; then
        ci_fail "No ${label} found in $search_dir matching $file_glob"
    fi

    if [ "${#matches[@]}" -gt 1 ]; then
        ci_fail "Expected exactly one ${label} in $search_dir matching $file_glob, found ${#matches[@]}"
    fi

    printf '%s\n' "${matches[0]}"
}

assert_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local failure_message="$3"

    require_file "$file_path"
    if ! grep -Eq "$pattern" "$file_path"; then
        ci_fail "$failure_message"
    fi
}
