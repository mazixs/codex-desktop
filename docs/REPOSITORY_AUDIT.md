# Repository Audit

## Executive Summary

The repository solves a real problem and the core direction is technically sound: use the official macOS package as input, rebuild native modules locally for Linux, and patch the Electron runtime where macOS-only behavior breaks Linux compositors or startup paths.

The previous implementation, however, had four structural weaknesses:

1. The runtime launcher was bound to an absolute filesystem path from one workstation.
2. The build produced side effects on the build machine such as desktop entry installation during normal runs.
3. There was no automated validation for shell logic, build reproducibility, or release generation.
4. Releases had no deterministic changelog or artifact publication flow.

These weaknesses are now addressed with a portable launcher, a tag-driven release workflow, and documentation of the project constraints.

## What Is Correct In The Existing Approach

### 1. Upstream DMG As The Single Source Of Truth

Using the official `Codex.dmg` as the input is the right baseline. It avoids republishing modified upstream source trees and keeps the adaptation anchored to a real upstream release artifact.

### 2. Rebuilding Native Modules Locally

Replacing macOS-native `.node` binaries with Linux ELF builds is mandatory. Rebuilding `better-sqlite3` and `node-pty` locally against Electron headers is the correct compatibility strategy.

### 3. CLI Fallback Via `@openai/codex`

The macOS bundle ships a platform-specific backend binary. Replacing that with the published `@openai/codex` CLI on Linux is a pragmatic and maintainable fallback.

### 4. Linux Graphics Patch Layer

The transparency and vibrancy fixes are justified. Without them, Linux compositors can render the application transparent or unstable.

## What Was Wrong Or Risky

### 1. Hardcoded Runtime Paths

The previous `start.sh` referenced Electron using an absolute path inside one local checkout. That made the generated launcher unusable everywhere else, including CI and release artifacts.

### 2. Hidden Mutable State

The old build path depended heavily on pre-existing extracted files and generated launch scripts directly inside the repository. That increased drift between one machine and another.

### 3. Silent Patch Fragility

String replacement against a minified `main.js` is acceptable only if critical replacements are guarded. Without checks, upstream bundle changes can produce successful-looking but broken builds.

### 4. No Release Contract

Before this iteration, the repository did not define:

- what a release artifact is
- how it is produced
- how changelog text is assembled
- how tags map to published binaries

That made versioned distribution unreliable.

## Optimal Path For This Repository

Given the current architecture, the optimal path is not a full rewrite. The right move is to stabilize the existing build around reproducibility and observability:

1. Keep the DMG-to-Linux adaptation model.
2. Add guardrails around patch application.
3. Separate build, local desktop installation, and release packaging concerns.
4. Publish one portable Linux artifact plus one installable Arch Linux package per tag.
5. Generate release notes from commits between tags so every iteration is traceable.

That is the path implemented in this repository now.

## Remaining Technical Limits

These are real limits of the project, not missing work:

- The port depends on reverse-engineered upstream bundle structure.
- A future upstream rename inside minified code can invalidate patch points.
- The project still does not have a full automated runtime UI test suite for the adapted application.
- Releases now include a native Arch Linux installer package, but there is still no `.deb` or `.rpm` pipeline.
- The release workflow builds on Linux `x64` only.

## Recommended Next Steps

If you want to harden the project further, the next high-value steps are:

1. Capture a machine-readable patch manifest with expected hashes or anchor strings for upstream bundle versions.
2. Add a headless smoke test that boots Electron and confirms the main window initializes.
3. Move from plain commit-based release notes to a convention-driven changelog if the commit discipline becomes consistent.
4. Add an installer path for native packages only after the portable artifact remains stable across several upstream updates.
