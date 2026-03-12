#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=./ci-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ci-lib.sh"
OUTPUT_PATH=""
REF=""
METADATA_PATH=""

usage() {
    cat <<'EOF'
Usage: ./scripts/generate-release-notes.sh --ref <git-ref> [--metadata <build-metadata.env>] [--output <path>]

Options:
  --ref REF       Git tag or commit-ish to build notes for
  --metadata PATH Optional build-metadata.env to derive exact artifact names/version
  --output PATH   Write release notes to PATH instead of stdout
  --help          Show this help
EOF
}

convert_remote_to_https() {
    local remote_url="$1"

    case "$remote_url" in
        git@github.com:*)
            printf 'https://github.com/%s\n' "${remote_url#git@github.com:}"
            ;;
        https://github.com/*)
            printf '%s\n' "$remote_url"
            ;;
        *)
            return 1
            ;;
    esac
}

append_commit_notes() {
    local range="$1"

    git log --reverse --format='%h%x1f%s%x1f%b%x00' "$range" |
        while IFS= read -r -d '' entry; do
            local short_hash=""
            local subject=""
            local body=""

            entry="${entry#$'\n'}"
            short_hash="${entry%%$'\x1f'*}"
            entry="${entry#*$'\x1f'}"
            subject="${entry%%$'\x1f'*}"
            body="${entry#*$'\x1f'}"

            printf -- "- \`%s\` %s\n" "$short_hash" "$subject"
            if [ -n "$body" ]; then
                printf '  Comment:\n'
                printf '%s\n' "$body" | sed 's/^/    /'
            fi
        done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ref)
                if [ "$#" -lt 2 ]; then
                    printf 'Missing value for --ref\n' >&2
                    exit 1
                fi
                REF="$2"
                shift 2
                ;;
            --output)
                if [ "$#" -lt 2 ]; then
                    printf 'Missing value for --output\n' >&2
                    exit 1
                fi
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --metadata)
                if [ "$#" -lt 2 ]; then
                    printf 'Missing value for --metadata\n' >&2
                    exit 1
                fi
                METADATA_PATH="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

main() {
    local previous_tag=""
    local compare_range=""
    local commit_count=""
    local ref_commit=""
    local release_date=""
    local release_version=""
    local upstream_version=""
    local remote_url=""
    local compare_url=""
    local notes_file=""
    local portable_asset_name=""
    local arch_asset_name=""

    parse_args "$@"

    if [ -z "$REF" ]; then
        printf -- '--ref is required\n' >&2
        usage >&2
        exit 1
    fi

    cd "$PROJECT_ROOT"

    if [ -n "$METADATA_PATH" ]; then
        if [ ! -f "$METADATA_PATH" ]; then
            printf 'Metadata file not found: %s\n' "$METADATA_PATH" >&2
            exit 1
        fi
        # shellcheck disable=SC1090
        source "$METADATA_PATH"
        release_version="${RELEASE_VERSION:-}"
        upstream_version="${UPSTREAM_VERSION:-}"
        portable_asset_name="${PORTABLE_ARCHIVE_NAME:-}"
        if [ -n "$release_version" ]; then
            arch_asset_name="$(arch_release_filename "$release_version")"
        elif [ -n "$upstream_version" ]; then
            arch_asset_name="$(arch_release_filename "$upstream_version")"
        fi
    fi

    ref_commit="$(git rev-parse "$REF^{commit}")"
    release_date="$(git log -1 --format=%cs "$ref_commit")"
    previous_tag="$(git describe --tags --abbrev=0 "$ref_commit^" 2>/dev/null || true)"

    if [ -n "$previous_tag" ]; then
        compare_range="${previous_tag}..${ref_commit}"
    else
        compare_range="$ref_commit"
    fi

    commit_count="$(git rev-list --count "$compare_range")"
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if remote_url="$(convert_remote_to_https "$remote_url" 2>/dev/null)"; then
        remote_url="${remote_url%.git}"
        if [ -n "$previous_tag" ]; then
            compare_url="$remote_url/compare/$previous_tag...$REF"
        fi
    else
        compare_url=""
    fi

    if [ -z "$upstream_version" ] && [ -f "$PROJECT_ROOT/codex-linux-build/dist/package.json" ]; then
        upstream_version="$(node -e 'console.log(require(process.argv[1]).version)' "$PROJECT_ROOT/codex-linux-build/dist/package.json" 2>/dev/null || true)"
    fi

    if [ -z "$release_version" ]; then
        release_version="${upstream_version:-}"
    fi

    if [ -z "$portable_asset_name" ] && [ -n "$release_version" ]; then
        portable_asset_name="$(portable_release_filename "$release_version")"
    fi

    if [ -z "$arch_asset_name" ] && [ -n "$release_version" ]; then
        arch_asset_name="$(arch_release_filename "$release_version")"
    fi

    notes_file="$(mktemp)"
    {
        printf '# %s\n\n' "$REF"
        printf 'Release date: %s\n\n' "$release_date"
        printf 'Prebuilt native Linux release built from the upstream Codex Desktop DMG, patched for Linux, and shipped with bundled Electron.\n\n'
        printf '## Release Assets\n\n'
        if [ -n "$arch_asset_name" ]; then
            printf -- "- Arch Linux installer: \`%s\`\n" "$arch_asset_name"
        else
            printf -- "- Arch Linux installer: \`codex-desktop-native-<upstream-version>-archlinux-x86_64.pkg.tar.zst\`\n"
        fi
        if [ -n "$portable_asset_name" ]; then
            printf -- "- Portable Linux archive: \`%s\`\n" "$portable_asset_name"
        else
            printf -- "- Portable Linux archive: \`codex-desktop-native-<upstream-version>-linux-portable-x64.tar.gz\`\n"
        fi
        printf '\n## Migration\n\n'
        printf -- "- Arch package name has changed from \`codex-desktop-bin\` to \`codex-desktop-native\`.\n"
        printf -- "- Launcher/runtime desktop id remains \`codex-desktop\`; the shell command \`codex\` remains owned by \`codex-cli\`.\n"
        printf '## Scope\n\n'
        if [ -n "$previous_tag" ]; then
            printf -- "- Previous tag: \`%s\`\n" "$previous_tag"
            printf -- "- Commit range: \`%s..%s\`\n" "$previous_tag" "$REF"
        else
            printf -- '- Previous tag: none\n'
            printf -- "- Commit range: full history through \`%s\`\n" "$REF"
        fi
        printf -- '- Included commits: %s\n' "$commit_count"
        if [ -n "$upstream_version" ]; then
            printf -- "- Upstream Codex version inside artifact: \`%s\`\n" "$upstream_version"
        fi
        if [ -n "$compare_url" ]; then
            printf -- '- Compare: [%s](%s)\n' "$compare_url" "$compare_url"
        fi
        printf '\n## Included commit comments\n\n'
        append_commit_notes "$compare_range"
    } > "$notes_file"

    if [ -n "$OUTPUT_PATH" ]; then
        mkdir -p "$(dirname "$OUTPUT_PATH")"
        mv "$notes_file" "$OUTPUT_PATH"
    else
        cat "$notes_file"
        rm -f "$notes_file"
    fi
}

main "$@"
