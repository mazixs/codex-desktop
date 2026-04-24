# Repository Guidelines

## Project Structure & Module Organization
This repository packages the official macOS Codex Desktop app for Linux. Most editable source lives in `codex-linux-build/`, especially `build.sh`, `start.sh`, and `webview-server.js`. Repository-wide automation lives in `scripts/`, Arch packaging files live in `packaging/arch/` and `packaging/aur/`, and process documentation lives in `docs/`. GitHub Actions workflows are under `.github/workflows/`.

Treat `codex-linux-build/dist/`, `codex-linux-build/artifacts/`, `codex-linux-build/native-rebuild/`, and `codex_extracted/` as generated outputs or caches. Do not hand-edit them unless a task explicitly targets generated artifacts.
When validating upstream bundle changes, remember that `./build.sh --clean` does not remove `codex_extracted/`. If a new `Codex.dmg` or a CI patch failure suggests upstream internals changed, delete `codex_extracted/` or build with a fresh DMG path to avoid testing against stale extracted sources.

## Build, Test, and Development Commands
Run Node-based commands from `codex-linux-build/`:

- `pnpm install --frozen-lockfile`: install pinned dependencies.
- `pnpm run build`: download/extract the upstream DMG and produce `dist/`.
- `pnpm run build:clean`: rebuild from a clean local state.
- `pnpm run package:portable`: create the portable Linux archive in `codex-linux-build/artifacts/`.
- `pnpm run verify`: syntax-check the shell entrypoints and confirm helper scripts expose valid `--help` output.

For upstream refresh work, prefer a truly fresh path:

- `rm -rf codex_extracted && ./codex-linux-build/build.sh --clean --package --dmg /tmp/Codex.dmg`: reproduces CI-style extraction and patching against a newly downloaded DMG.

Run repository-level validation from the repo root:

- `./scripts/validate-workflows.sh`: lint `.github/workflows/*.yml` with `actionlint` and `shellcheck`.
- `./scripts/build-arch-package.sh --source codex-linux-build/artifacts/*.tar.gz --metadata codex-linux-build/artifacts/build-metadata.env --output-dir codex-linux-build/artifacts`: build the Arch package from a portable artifact.

## Coding Style & Naming Conventions
Shell is the primary implementation language. Follow existing Bash style: `#!/usr/bin/env bash`, `set -euo pipefail`, quoted variables, and small helper functions for repeated logic. Use four-space indentation in shell blocks. Keep filenames descriptive and kebab-case for scripts such as `verify-release-assets.sh`.

Use `shellcheck` for shell scripts and `actionlint` for workflow changes. Avoid introducing formatting-only churn in generated or vendored paths.

## Testing Guidelines
There is no separate unit-test suite; CI is contract-driven. Before opening a PR, run `pnpm run verify` and, when touching workflows or packaging, run `./scripts/validate-workflows.sh`. If you change artifact layout or launch behavior, also run `pnpm run package:portable` and the relevant verification scripts.
If the change is driven by a new upstream DMG, also verify against a fresh extraction rather than a reused `codex_extracted/` cache, then smoke-test with `./codex-linux-build/start.sh`.

## Commit & Pull Request Guidelines
Recent history follows Conventional Commits with scopes, for example `fix(ci): ...`, `refactor(ci): ...`, and `docs(readme): ...`. Keep subjects imperative and concise.

PRs should explain the Linux packaging impact, list the local commands you ran, and link the relevant issue or release task when available. Include screenshots only for visible launcher or desktop-entry changes; otherwise attach the exact artifact or smoke-test evidence that proves the change.
