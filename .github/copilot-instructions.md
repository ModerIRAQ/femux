# Femux — Project Guidelines

## Overview
Femux is a **desktop-only** Flutter terminal manager that wraps native OS shells (PowerShell on Windows, bash/zsh on Linux/macOS). It aims to be an ultra-lightweight, long-running tmux-like experience with a polished desktop UI.

## Architecture
- **Single entry point**: `lib/main.dart` — currently a monolith; split into files under `lib/` as features grow (e.g., `lib/models/`, `lib/widgets/`, `lib/providers/`).
- **State models**: `TerminalInstance` (wraps `Terminal` + `Pty`) and `WorkspaceTab` (owns a list of `TerminalInstance`).
- **Split panes**: `MultiSplitView` with a `builder`/`initialAreas` API (not `children`). Each area gets equal flex. Triggered by **Ctrl+D** or a UI button.
- **Tabs**: Custom title-bar tabs with drag-to-move window support via `window_manager`.
- **Folder picker**: Long-press the **+** button to open `file_picker` directory chooser, setting the PTY working directory.
- **Theme**: Dracula palette defined in `DraculaColors` constants; terminal theme in `terminalTheme`.

## Code Style
- Dart SDK `^3.9.0`, analysis via `package:flutter_lints/flutter.yaml`.
- Use `const` constructors wherever possible.
- Prefer named parameters with `required` for model constructors.
- Keep widget trees readable — extract widgets into separate classes when a `build` method exceeds ~80 lines.

## Key Dependencies
| Package | Purpose |
|---|---|
| `flutter_pty` | Spawn native PTY processes |
| `xterm` | Terminal emulator widget (`TerminalView`, `Terminal`) |
| `window_manager` | Custom title bar, window controls, drag |
| `multi_split_view` | Resizable split panes (use `builder` + `initialAreas`, **not** `children`) |
| `file_picker` | Directory picker for workspace folders |
| `shared_preferences` | Persist user settings (default shell path) |
| `flutter_riverpod` | Declared for future state management — migrate to it when splitting files |

## Build & Run
```bash
flutter pub get
flutter run -d windows   # or -d linux / -d macos
flutter build windows     # release build
```

## Performance Constraints
- Target: run for days with minimal RAM/CPU footprint.
- `Terminal(maxLines: 10000)` — do not raise without profiling.
- Dispose every `Pty` on tab/pane close (`pty.kill()`).
- Avoid rebuilding the entire widget tree on state changes — prefer granular `setState` or Riverpod providers scoped to individual panes.
- No unnecessary timers, animations, or polling loops.

## Project Conventions
- **Desktop only** — no mobile/web targets. UI assumes mouse, keyboard, and resizable windows.
- **Keyboard shortcuts**: Ctrl+T (new tab), Ctrl+W (close tab), Ctrl+D (split pane), Ctrl+Shift+D (split in folder). Document new shortcuts in this file and PROGRESS.md.
- **Dracula theme only** (for now) — all colors come from `DraculaColors`.
- **No tests yet** — add widget tests in `test/` as the app grows. Run with `flutter test`.
- `cupertino_icons` is unused — safe to remove.

## Platform Runners
Stock Flutter scaffolds in `windows/`, `linux/`, `macos/`. Native window size (1280×720) is overridden by `WindowOptions(size: Size(1000, 700))` in Dart. Edit Dart-side values, not native runners, for window defaults.
