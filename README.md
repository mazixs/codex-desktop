<div align="center">
  <img src="assets/codex-logo.png" alt="OpenAI Codex Logo" width="128" height="128" />
  <h1>OpenAI Codex Desktop for Linux</h1>
  <p><b>Native Linux packaging and release tooling for the official macOS Codex Desktop app.</b></p>
</div>

## Overview

This repository adapts the official macOS Codex Desktop distribution to Linux by:

- downloading the upstream `Codex.dmg`
- extracting `app.asar`
- rebuilding macOS-native modules as Linux ELF binaries
- patching Linux-incompatible Electron code paths
- packaging a portable Linux artifact and an installable Arch Linux package

The project remains an unofficial port. The technical approach works, but it is inherently coupled to upstream bundle internals and should be treated as a maintained compatibility layer, not a stable public API.

## Current Status

What is validated:

- the repository now builds a prebuilt native Linux release from a tagged pipeline
- release notes are generated automatically from commit history between tags
- CI runs workflow linting, shell validation, portable packaging, release-contract checks, and Arch install/launch smoke tests on GitHub Actions
- the built-in file manager works on Linux and can open both file locations and individual files
- voice input works on Linux
- the current Linux build avoids the graphical glitches that are common in other unofficial Codex Desktop Linux solutions

What is still fragile by design:

- patching happens against a minified upstream `main.js`
- upstream changes can break string-based patches without warning unless the guard checks catch them
- the runtime is Linux `x64` only at the moment

The detailed technical audit lives in [docs/REPOSITORY_AUDIT.md](docs/REPOSITORY_AUDIT.md).

## Local Build

### Prerequisites

- `node`, `npm`, `pnpm`
- `python3`
- `7z`
- `file`
- base toolchain (`build-essential` on Debian/Ubuntu, `base-devel` on Arch)

### Commands

```bash
git clone https://github.com/mazixs/codex-desktop.git
cd codex-desktop/codex-linux-build
pnpm install --frozen-lockfile
pnpm run build
./start.sh
```

To create the same portable artifact used in releases:

```bash
pnpm run package:portable
```

Artifacts are written to `codex-linux-build/artifacts/`.

To produce the Arch Linux package locally after the portable archive is ready:

```bash
./scripts/build-arch-package.sh \
  --source codex-linux-build/artifacts/*.tar.gz \
  --metadata codex-linux-build/artifacts/build-metadata.env \
  --output-dir codex-linux-build/artifacts
```

## Release Flow

The repository now uses a tag-driven release process:

```bash
git tag v1.0.0
git push origin v1.0.0
```

After the tag is pushed:

- GitHub Actions builds the portable Linux archive `codex-desktop-native-<upstream-version>-linux-portable-x64.tar.gz`
- a second job turns that artifact into the installable Arch Linux package `codex-desktop-native-<upstream-version>-archlinux-x86_64.pkg.tar.zst`
- `scripts/generate-release-notes.sh` collects commit subjects and bodies since the previous tag and derives platform-specific asset names from `build-metadata.env`
- the workflow creates or updates the GitHub Release and uploads both packages plus checksums

The CI/CD details are documented in [docs/CI_CD.md](docs/CI_CD.md). Each tagged release now publishes both a portable Linux archive and an Arch Linux installer, both with bundled Electron.

## CI/CD Contract

The repository treats CI/CD as a product contract, not a best-effort build:

- Node is pinned to `24` in GitHub Actions
- `pnpm` is activated only through `corepack` using the version from `codex-linux-build/package.json`
- workflow syntax is linted with `actionlint`
- the portable artifact must contain bundled Electron, Linux icons, packaged skill overrides, metadata, and a working launcher
- the Arch artifact must install through `pacman -U`, contain the bundled runtime under `/opt/codex-desktop`, and survive a headless smoke launch
- releases are only published after the asset contract, checksums, metadata, and release notes all validate

Repo-controlled regressions should fail with deterministic messages. External failures such as GitHub outages, upstream DMG CDN issues, or package mirror/network errors remain outside the repository's control and are treated as retriable infrastructure failures.

## Repository Layout

- `codex-linux-build/` build toolchain, launcher, packaging logic
- `scripts/` repository-level automation such as release note generation
- `docs/` architecture, reverse engineering notes, audit, and CI/CD documentation
- `codex_extracted/` optional local extraction cache, ignored by git

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/TECHNICAL_DETAILS.md](docs/TECHNICAL_DETAILS.md)
- [docs/REPOSITORY_AUDIT.md](docs/REPOSITORY_AUDIT.md)
- [docs/CI_CD.md](docs/CI_CD.md)

## Limitations

- The upstream application is distributed for macOS, so Linux compatibility depends on reverse-engineered patch points.
- This repository does not publish an official upstream build; it automates a local adaptation.
- If upstream Electron internals, native module versions, or bundle structure change, the Linux build may need patch updates.

## License

Repository code is provided under [Apache-2.0](LICENSE). Upstream Codex application binaries remain subject to OpenAI's terms.
