# Femux

Femux is a desktop-first multi-pane terminal workspace built with Flutter.

## Features

- Multi-tab terminal workspace
- Split panes with resizable layout
- Per-pane folder split (`Ctrl+Shift+D`)
- Custom desktop title bar with window controls
- Tab rename and tab reorder
- Pane header with close + drag-to-reorder
- Configurable default shell in Settings
- Help window with shortcuts and usage tips

## Supported Platforms

- Windows
- Linux
- macOS

## Keyboard Shortcuts

- `Ctrl+T` new tab
- `Ctrl+W` close active tab
- `Ctrl+D` split active pane
- `Ctrl+Shift+D` split active pane and choose a folder

## Run Locally

### Prerequisites

- Flutter SDK (stable)
- Dart SDK (bundled with Flutter)

### Commands

```bash
flutter pub get
flutter run -d windows
```

For Linux/macOS replace the device target accordingly.

## Project Structure

- Main app logic: `lib/main.dart`
- Windows runner resources: `windows/runner/resources/`
- Linux runner native host: `linux/runner/`
- macOS runner resources: `macos/Runner/`

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening pull requests.

## Security

Please report security issues according to [SECURITY.md](SECURITY.md).

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE).
