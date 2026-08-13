# Agent Development Guide

Guidance for coding agents working in this fork of Ghostty.

## Commands

- Build: `nix --extra-experimental-features 'nix-command flakes' develop -c zig build`
  - On macOS, if you do not need the app bundle, use
    `nix --extra-experimental-features 'nix-command flakes' develop -c zig build -Demit-macos-app=false`
- Run GTK locally: `ghostty-dev run`
  - This Ubuntu/NVIDIA host requires a graphics-driver bridge for Nix-built GTK
    binaries. Direct execution, including through `nix develop`, can fail with
    `Failed to create EGL display`.
  - `~/.local/bin/ghostty-dev` uses a pinned `nixGL`, builds first when needed,
    and accepts Ghostty arguments after `run`.
- Test: `nix --extra-experimental-features 'nix-command flakes' develop -c zig build test`
  - Prefer targeted runs with `-Dtest-filter=<name>` because the full suite is slow
- Local shortcuts:
  - `ghostty-dev build`
  - `ghostty-dev test [-Dtest-filter=<name>]`
  - `ghostty-dev shell`
- Format Zig: `nix --extra-experimental-features 'nix-command flakes' develop -c zig fmt .`
- Format Swift: `swiftlint lint --strict --fix`
- Format other files: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Structure

- Shared Zig core: `src/`
- GTK app: `src/apprt/gtk`
- macOS app: `macos/`
- CLI entrypoints: `src/cli/`
- Renderer backends: `src/renderer/`

## Working Style

- Inspect the local code before making architectural assumptions.
- Prefer small, behavior-preserving refactors unless the task is explicitly feature work.
- Add or update targeted tests when changing behavior or fixing regressions.
- Use the narrowest test filter that covers the change, then run a full build before finishing.
- Do not revert unrelated user changes in the worktree.

## Branching And PRs

- This fork allows normal branch, push, and PR workflows.
- Target PRs according to the user’s instruction; do not assume upstream is the destination.
- When changing fork-specific workflow files like this one, keep the guidance useful and minimal.
