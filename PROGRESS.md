# Femux — Project Progress

## Feature Audit (2026-03-03)

### Core Requirements (from project plan)
| # | Feature | Status | Notes |
|---|---------|--------|-------|
| 1 | Native OS terminal (PowerShell/bash) | DONE | `flutter_pty` + `xterm` |
| 2 | Custom title bar with tabs | DONE | `window_manager` hidden title bar |
| 3 | Tab "+" button → new terminal | DONE | Click opens default dir |
| 4 | Tab "+" long-press → folder picker | DONE | `file_picker` directory picker |
| 5 | Tab close button | DONE | Per-tab X icon |
| 6 | Window drag, minimize, maximize, close | DONE | Title bar controls with tooltips |
| 7 | Split pane via Ctrl+D | DONE | `MultiSplitViewController` dynamic splits |
| 8 | Split pane via UI button | DONE | Orange split icon in title bar |
| 9 | Resizable split panes | DONE | `multi_split_view` controller API |
| 10 | Close individual pane in split | DONE | X overlay on each pane + right-click menu |
| 11 | Folder picker per pane | DONE | Right-click → "Split in folder…" or Ctrl+Shift+D |
| 12 | Desktop-optimized UI/UX | DONE | Tab reorder, right-click context menus, focus indicator, tooltips |
| 13 | Lightweight / low RAM footprint | DONE | Stream subscriptions cancelled, PTYs killed, focus nodes disposed |
| 14 | Keyboard shortcuts | DONE | Ctrl+T (new tab), Ctrl+W (close tab), Ctrl+D (split), Ctrl+Shift+D (split in folder) |
| 15 | Tab rename | DONE | Double-click tab title to edit inline |
| 16 | Persisted settings | DONE | `shared_preferences` for default shell |
| 17 | Tab reorder via drag | DONE | `ReorderableListView` in tab bar |
| 18 | Pane count badge on tab | DONE | Shows number when >1 pane open |

### Bugs / Issues Fixed
| # | Issue | Status | Fix |
|---|-------|--------|-----|
| B1 | `MultiSplitView` not reactive to new splits | FIXED | Switched to `MultiSplitViewController` with `addArea`/`removeAreaAt` |
| B2 | `_keyboardFocusNode` never disposed | FIXED | Added `dispose()` override |
| B3 | Tab PTY streams never cancelled | FIXED | `TerminalInstance` now stores and cancels `StreamSubscription` |
| B4 | `flutter_riverpod` unused dependency | FIXED | Removed from `pubspec.yaml` |
| B5 | `cupertino_icons` unused dependency | FIXED | Removed from `pubspec.yaml` |
| B6 | No `dispose()` in `_MainWorkspaceState` | FIXED | Full cleanup: focus node, rename controller, all tab PTYs |
| B7 | PTY wiring duplicated in 3 places | FIXED | Extracted `TerminalInstance.spawn()` factory |
