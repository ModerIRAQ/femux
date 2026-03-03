import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefDefaultShell = 'defaultShell';
const _prefWindowMaximized = 'windowMaximized';

bool _isBenignTextInputPlatformException(Object error) {
  if (error is! PlatformException) {
    return false;
  }

  final payload = '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
      .toLowerCase();

  return payload.contains('view id is null') ||
      (payload.contains('set editing state') &&
          payload.contains('no client is set'));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final shouldStartMaximized = prefs.getBool(_prefWindowMaximized) ?? false;

  FlutterError.onError = (details) {
    if (_isBenignTextInputPlatformException(details.exception)) {
      return;
    }
    FlutterError.presentError(details);
  };

  // Suppress transient TextInput PlatformExceptions during window transitions
  // and hot restart focus churn.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (_isBenignTextInputPlatformException(error)) {
      return true; // handled – safe to ignore
    }
    return false;
  };

  const windowOptions = WindowOptions(
    size: Size(1280, 820),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (shouldStartMaximized) {
      await windowManager.maximize();
    }
    await windowManager.focus();
  });

  runApp(const FemuxApp());
}

// --- Theme ---
class DraculaColors {
  static const Color background = Color(0xFF282a36);
  static const Color currentLine = Color(0xFF44475a);
  static const Color foreground = Color(0xFFf8f8f2);
  static const Color comment = Color(0xFF6272a4);
  static const Color cyan = Color(0xFF8be9fd);
  static const Color green = Color(0xFF50fa7b);
  static const Color orange = Color(0xFFffb86c);
  static const Color pink = Color(0xFFff79c6);
  static const Color purple = Color(0xFFbd93f9);
  static const Color red = Color(0xFFff5555);
  static const Color yellow = Color(0xFFf1fa8c);
}

final terminalTheme = TerminalTheme(
  cursor: DraculaColors.cyan,
  selection: DraculaColors.comment,
  foreground: DraculaColors.foreground,
  background: DraculaColors.background,
  black: const Color(0xFF21222c),
  red: DraculaColors.red,
  green: DraculaColors.green,
  yellow: DraculaColors.yellow,
  blue: DraculaColors.purple,
  magenta: DraculaColors.pink,
  cyan: DraculaColors.cyan,
  white: DraculaColors.foreground,
  brightBlack: DraculaColors.comment,
  brightRed: DraculaColors.red,
  brightGreen: DraculaColors.green,
  brightYellow: DraculaColors.yellow,
  brightBlue: DraculaColors.purple,
  brightMagenta: DraculaColors.pink,
  brightCyan: DraculaColors.cyan,
  brightWhite: const Color(0xFFffffff),
  searchHitBackground: DraculaColors.orange,
  searchHitBackgroundCurrent: DraculaColors.yellow,
  searchHitForeground: DraculaColors.background,
);

class FemuxApp extends StatelessWidget {
  const FemuxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Femux',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: DraculaColors.background,
        colorScheme: const ColorScheme.dark(
          primary: DraculaColors.purple,
          secondary: DraculaColors.pink,
          surface: DraculaColors.currentLine,
        ),
      ),
      home: const MainWorkspace(),
    );
  }
}

// --- State Models ---
class TerminalInstance {
  final String id;
  final Terminal terminal;
  final Pty pty;
  final StreamSubscription<String> _outputSubscription;

  TerminalInstance._({
    required this.id,
    required this.terminal,
    required this.pty,
    required StreamSubscription<String> outputSubscription,
  }) : _outputSubscription = outputSubscription;

  /// Factory that wires up PTY ↔ Terminal and returns a fully connected instance.
  factory TerminalInstance.spawn(String shellPath, {String? workingDirectory}) {
    final executable = _shellExecutable(shellPath);
    final shellArgs = _shellArguments(shellPath);
    final shellEnvironment = _shellEnvironment(shellPath);

    final pty = Pty.start(
      executable,
      arguments: shellArgs,
      workingDirectory: workingDirectory,
      environment: shellEnvironment,
    );

    final terminal = Terminal(maxLines: 10000);

    final sub = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen((text) {
          terminal.write(text);
        });

    terminal.onOutput = (text) {
      pty.write(const Utf8Encoder().convert(text));
    };

    terminal.onResize = (w, h, pw, ph) {
      try {
        pty.resize(h, w);
      } catch (_) {
        // Ignore resize errors during window transitions
      }
    };

    return TerminalInstance._(
      id: UniqueKey().toString(),
      terminal: terminal,
      pty: pty,
      outputSubscription: sub,
    );
  }

  void dispose() {
    _outputSubscription.cancel();
    pty.kill();
  }
}

String _shellName(String shellPath) {
  final lower = shellPath.trim().toLowerCase();
  final base = lower.split(RegExp(r'[\\/]')).last;
  return base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
}

String _shellExecutable(String shellPath) {
  if (!Platform.isWindows) {
    return shellPath;
  }

  final name = _shellName(shellPath);
  if (name == 'pwsh' || name == 'powershell') {
    // Work around flutter_pty argument parsing quirks on Windows by
    // launching PowerShell through cmd.
    return 'cmd.exe';
  }

  return shellPath;
}

List<String> _shellArguments(String shellPath) {
  if (!Platform.isWindows) {
    return ['-l'];
  }

  final name = _shellName(shellPath);
  if (name == 'pwsh') {
    return ['/D', '/Q', '/K', 'pwsh.exe -NoLogo -NoProfile'];
  }

  if (name == 'powershell') {
    return ['/D', '/Q', '/K', 'powershell.exe -NoLogo -NoProfile'];
  }

  if (name == 'cmd') {
    return ['/D', '/Q'];
  }

  return [];
}

Map<String, String>? _shellEnvironment(String shellPath) {
  if (!Platform.isWindows) {
    return null;
  }

  final env = Platform.environment;
  final result = <String, String>{};

  const keys = [
    'PATH',
    'USERPROFILE',
    'HOMEDRIVE',
    'HOMEPATH',
    'HOME',
    'APPDATA',
    'LOCALAPPDATA',
    'TEMP',
    'TMP',
    'SystemRoot',
    'WINDIR',
    'COMSPEC',
    'PATHEXT',
    'PSModulePath',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'ProgramW6432',
    'PUBLIC',
    'USERNAME',
    'USERDOMAIN',
  ];

  for (final key in keys) {
    final value = env[key];
    if (value != null && value.isNotEmpty) {
      result[key] = value;
    }
  }

  // PowerShell relies on a valid user home when initializing FileSystem drives.
  result['HOME'] = result['HOME'] ?? result['USERPROFILE'] ?? '';

  // Do not pass an empty HOME.
  if (result['HOME']!.isEmpty) {
    result.remove('HOME');
  }

  return result;
}

String _resolveShellPath(String preferredShell) {
  if (!Platform.isWindows) {
    return preferredShell.isNotEmpty ? preferredShell : 'bash';
  }

  final normalized = preferredShell.trim();
  if (normalized.isEmpty) {
    return 'cmd.exe';
  }

  if (normalized.contains('\\') || normalized.contains('/')) {
    return File(normalized).existsSync() ? normalized : 'cmd.exe';
  }

  return normalized;
}

List<String> _buildShellCandidates(String preferredShell) {
  if (!Platform.isWindows) {
    return <String>{_resolveShellPath(preferredShell), 'bash'}.toList();
  }

  // Keep cmd as a guaranteed fallback, with PowerShell variants available
  // through cmd-based wrappers.
  return <String>{
    _resolveShellPath(preferredShell),
    'cmd.exe',
    'pwsh.exe',
    'powershell.exe',
  }.toList();
}

List<String> _settingsShellOptions() {
  if (Platform.isWindows) {
    return ['cmd.exe', 'pwsh.exe', 'powershell.exe'];
  }
  if (Platform.isMacOS) {
    return ['zsh', 'bash', 'sh'];
  }
  if (Platform.isLinux) {
    return ['bash', 'zsh', 'sh'];
  }
  return ['bash'];
}

String _shellLabel(String shellPath) {
  final name = _shellName(shellPath);
  if (name == 'cmd') return 'Command Prompt (cmd.exe)';
  if (name == 'powershell') return 'Windows PowerShell (powershell.exe)';
  if (name == 'pwsh') return 'PowerShell 7 (pwsh.exe)';
  if (name == 'zsh') return 'Z Shell (zsh)';
  if (name == 'bash') return 'Bash (bash)';
  if (name == 'sh') return 'POSIX Shell (sh)';
  return shellPath;
}

class WorkspaceTab {
  final String id;
  String title;
  final List<TerminalInstance> terminals;
  final MultiSplitViewController splitController;
  String? focusedPaneId;

  WorkspaceTab({
    required this.id,
    required this.title,
    required this.terminals,
    required this.splitController,
    this.focusedPaneId,
  });

  void dispose() {
    for (final t in terminals) {
      t.dispose();
    }
  }
}

// --- Main UI ---
class MainWorkspace extends StatefulWidget {
  const MainWorkspace({super.key});

  @override
  State<MainWorkspace> createState() => _MainWorkspaceState();
}

class _MainWorkspaceState extends State<MainWorkspace> with WindowListener {
  final FocusNode _keyboardFocusNode = FocusNode();

  final List<WorkspaceTab> tabs = [];
  String? activeTabId;
  String defaultShellPath = Platform.isWindows ? 'cmd.exe' : 'bash';

  // For tab rename
  String? _renamingTabId;
  final TextEditingController _renameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addNewTab();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _keyboardFocusNode.dispose();
    _renameController.dispose();
    for (final tab in tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  // --- WindowListener: unfocus terminals during window state transitions ---
  @override
  void onWindowMaximize() {
    _unfocusDuringTransition();
    _saveWindowMaximized(true);
  }

  @override
  void onWindowUnmaximize() {
    _unfocusDuringTransition();
    _saveWindowMaximized(false);
  }

  @override
  void onWindowClose() async {
    try {
      final maximized = await windowManager.isMaximized();
      await _saveWindowMaximized(maximized);
    } catch (_) {}
  }

  void _unfocusDuringTransition() {
    FocusManager.instance.primaryFocus?.unfocus();
    // Restore keyboard focus after the transition settles.
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _keyboardFocusNode.requestFocus();
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedShell = prefs.getString(_prefDefaultShell);
    final options = _settingsShellOptions();
    final fallback = options.first;

    String resolved = _resolveShellPath(savedShell ?? defaultShellPath);
    if (!options.contains(resolved)) {
      resolved = fallback;
    }

    if (savedShell != null && savedShell.isNotEmpty) {
      setState(() {
        defaultShellPath = resolved;
      });
    } else {
      await prefs.setString(_prefDefaultShell, resolved);
      setState(() {
        defaultShellPath = resolved;
      });
    }
  }

  Future<void> _saveDefaultShell(String shell) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDefaultShell, shell);
    if (!mounted) return;
    setState(() {
      defaultShellPath = shell;
    });
  }

  Future<void> _saveWindowMaximized(bool isMaximized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefWindowMaximized, isMaximized);
  }

  Future<void> _toggleWindowMaximize() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } on PlatformException catch (_) {
      // Ignore transient platform errors during transition.
    }
  }

  Future<void> _openSettingsDialog() async {
    final options = _settingsShellOptions();
    String selected = options.contains(defaultShellPath)
        ? defaultShellPath
        : options.first;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: DraculaColors.currentLine,
              title: const Text(
                'Settings',
                style: TextStyle(color: DraculaColors.foreground),
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Default terminal (${Platform.operatingSystem})',
                      style: const TextStyle(
                        color: DraculaColors.comment,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selected,
                      dropdownColor: DraculaColors.currentLine,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(color: DraculaColors.foreground),
                      items: options
                          .map(
                            (shell) => DropdownMenuItem<String>(
                              value: shell,
                              child: Text(_shellLabel(shell)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          selected = value;
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    final messenger = ScaffoldMessenger.of(this.context);
                    _saveDefaultShell(selected).then((_) {
                      if (!mounted) return;
                      navigator.pop();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            'Default terminal set to ${_shellLabel(selected)}',
                          ),
                        ),
                      );
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openHelpDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: DraculaColors.currentLine,
          title: const Text(
            'Help & Shortcuts',
            style: TextStyle(color: DraculaColors.foreground),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Keyboard shortcuts',
                    style: TextStyle(
                      color: DraculaColors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _helpRow('Ctrl+T', 'Open a new terminal tab'),
                  _helpRow('Ctrl+W', 'Close active tab'),
                  _helpRow('Ctrl+D', 'Split active pane'),
                  _helpRow(
                    'Ctrl+Shift+D',
                    'Split active pane and choose a folder',
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Mouse tricks',
                    style: TextStyle(
                      color: DraculaColors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _helpRow('Double-click tab', 'Rename tab'),
                  _helpRow('Drag tab', 'Reorder tabs'),
                  _helpRow('Long-press +', 'Open new tab in selected folder'),
                  _helpRow('Right-click pane', 'Open pane menu (split/close)'),
                  _helpRow('Close icon in pane', 'Close that pane'),
                  const SizedBox(height: 14),
                  const Text(
                    'Title bar actions',
                    style: TextStyle(
                      color: DraculaColors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _helpRow('Split button', 'Split pane quickly'),
                  _helpRow('Settings button', 'Choose default terminal for OS'),
                  _helpRow('Help button', 'Open this help window'),
                  _helpRow('Window controls', 'Minimize / maximize / close'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _helpRow(String key, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              key,
              style: const TextStyle(
                color: DraculaColors.yellow,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(
                color: DraculaColors.foreground,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addNewTab({String? workingDirectory}) {
    TerminalInstance? instance;

    final shellCandidates = _buildShellCandidates(defaultShellPath);

    for (final shell in shellCandidates) {
      try {
        instance = TerminalInstance.spawn(
          shell,
          workingDirectory: workingDirectory,
        );
        defaultShellPath = shell;
        break;
      } catch (_) {
        continue;
      }
    }

    if (instance == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to start a shell (pwsh/powershell/cmd).'),
          ),
        );
      }
      return;
    }

    final controller = MultiSplitViewController();
    controller.areas = [Area(flex: 1, data: instance.id)];

    final newTab = WorkspaceTab(
      id: UniqueKey().toString(),
      title: workingDirectory != null
          ? workingDirectory.split(Platform.pathSeparator).last
          : 'Terminal',
      terminals: [instance],
      splitController: controller,
      focusedPaneId: instance.id,
    );

    setState(() {
      tabs.add(newTab);
      activeTabId = newTab.id;
    });
  }

  void _splitPane(WorkspaceTab tab, {String? workingDirectory}) {
    TerminalInstance? instance;
    final shellCandidates = _buildShellCandidates(defaultShellPath);

    for (final shell in shellCandidates) {
      try {
        instance = TerminalInstance.spawn(
          shell,
          workingDirectory: workingDirectory,
        );
        defaultShellPath = shell;
        break;
      } catch (_) {
        continue;
      }
    }

    if (instance == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to split pane: no shell could be started.'),
          ),
        );
      }
      return;
    }

    tab.terminals.add(instance);
    tab.splitController.addArea(Area(flex: 1, data: instance.id));
    tab.focusedPaneId = instance.id;

    setState(() {});
  }

  void _closePane(WorkspaceTab tab, int paneIndex) {
    if (tab.terminals.length <= 1) {
      // Last pane — close entire tab
      _closeTab(tab);
      return;
    }

    final instance = tab.terminals[paneIndex];
    instance.dispose();
    tab.terminals.removeAt(paneIndex);
    tab.splitController.removeAreaAt(paneIndex);

    if (tab.focusedPaneId == instance.id && tab.terminals.isNotEmpty) {
      tab.focusedPaneId = tab.terminals.first.id;
    }

    setState(() {});
  }

  void _reorderPanes(WorkspaceTab tab, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    if (fromIndex < 0 || toIndex < 0) return;
    if (fromIndex >= tab.terminals.length || toIndex >= tab.terminals.length) {
      return;
    }

    var targetIndex = toIndex;
    if (fromIndex < toIndex) {
      targetIndex -= 1;
    }

    final movedTerminal = tab.terminals.removeAt(fromIndex);
    tab.terminals.insert(targetIndex, movedTerminal);

    final reorderedAreas = tab.splitController.areas.toList(growable: true);
    final movedArea = reorderedAreas.removeAt(fromIndex);
    reorderedAreas.insert(targetIndex, movedArea);
    tab.splitController.areas = reorderedAreas;

    tab.focusedPaneId = movedTerminal.id;
    setState(() {});
  }

  void _closeTab(WorkspaceTab tab) {
    tab.dispose();
    setState(() {
      tabs.remove(tab);
      if (activeTabId == tab.id) {
        activeTabId = tabs.isNotEmpty ? tabs.last.id : null;
      }
    });
  }

  Future<void> _pickFolderForPane(WorkspaceTab tab) async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      _splitPane(tab, workingDirectory: dir);
    }
  }

  WorkspaceTab? get _activeTab {
    if (activeTabId == null) return null;
    return tabs.where((t) => t.id == activeTabId).firstOrNull;
  }

  void _startRenameTab(WorkspaceTab tab) {
    setState(() {
      _renamingTabId = tab.id;
      _renameController.text = tab.title;
    });
  }

  void _commitRename(WorkspaceTab tab) {
    final newTitle = _renameController.text.trim();
    setState(() {
      if (newTitle.isNotEmpty) {
        tab.title = newTitle;
      }
      _renamingTabId = null;
    });
  }

  // --- Keyboard shortcut handler ---
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;

    // Ctrl+T → new tab
    if (ctrl && key == LogicalKeyboardKey.keyT) {
      _addNewTab();
      return KeyEventResult.handled;
    }

    // Ctrl+W → close active tab
    if (ctrl && key == LogicalKeyboardKey.keyW) {
      final tab = _activeTab;
      if (tab != null) _closeTab(tab);
      return KeyEventResult.handled;
    }

    // Ctrl+D → split pane horizontally
    if (ctrl && !shift && key == LogicalKeyboardKey.keyD) {
      final tab = _activeTab;
      if (tab != null) _splitPane(tab);
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+D → split with folder picker
    if (ctrl && shift && key == LogicalKeyboardKey.keyD) {
      final tab = _activeTab;
      if (tab != null) _pickFolderForPane(tab);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // --- Build ---
  @override
  Widget build(BuildContext context) {
    final activeTab = _activeTab;

    return Scaffold(
      body: Focus(
        autofocus: true,
        focusNode: _keyboardFocusNode,
        onKeyEvent: _handleKeyEvent,
        child: Column(
          children: [
            _buildTitleBar(),
            Expanded(
              child: activeTab == null
                  ? _buildEmptyState()
                  : _buildTerminalArea(activeTab),
            ),
          ],
        ),
      ),
    );
  }

  // --- Title bar ---
  Widget _buildTitleBar() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: _toggleWindowMaximize,
      child: Container(
        height: 40,
        color: DraculaColors.currentLine,
        child: Row(
          children: [
            const SizedBox(width: 10),
            const Text(
              'Femux',
              style: TextStyle(
                color: DraculaColors.cyan,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 12),

            // Tabs (reorderable)
            Expanded(child: _buildTabBar()),

            // Split pane button
            _titleBarIconButton(
              icon: Icons.vertical_split,
              tooltip: 'Split pane (Ctrl+D) · Split in folder (Ctrl+Shift+D)',
              color: DraculaColors.orange,
              onTap: () {
                final tab = _activeTab;
                if (tab != null) _splitPane(tab);
              },
            ),

            _titleBarIconButton(
              icon: Icons.settings,
              tooltip: 'Settings',
              onTap: _openSettingsDialog,
            ),
            _titleBarIconButton(
              icon: Icons.help_outline,
              tooltip: 'Help & shortcuts',
              onTap: _openHelpDialog,
            ),

            // New tab button (long-press for folder)
            Tooltip(
              message: 'New tab · Long-press to pick folder',
              child: GestureDetector(
                onTap: () => _addNewTab(),
                onLongPress: () async {
                  final dir = await FilePicker.platform.getDirectoryPath();
                  if (dir != null) _addNewTab(workingDirectory: dir);
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.add, color: DraculaColors.green, size: 18),
                ),
              ),
            ),

            const SizedBox(width: 4),

            // Window controls
            _titleBarIconButton(
              icon: Icons.minimize,
              tooltip: 'Minimize',
              onTap: () => windowManager.minimize(),
            ),
            _titleBarIconButton(
              icon: Icons.crop_square,
              tooltip: 'Maximize',
              onTap: _toggleWindowMaximize,
            ),
            _titleBarIconButton(
              icon: Icons.close,
              tooltip: 'Close',
              color: DraculaColors.red,
              onTap: () => windowManager.close(),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _titleBarIconButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color color = DraculaColors.foreground,
  }) {
    final child = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 15, color: color),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: child) : child;
  }

  // --- Tab bar with drag-reorder ---
  Widget _buildTabBar() {
    return ReorderableListView.builder(
      scrollDirection: Axis.horizontal,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return Material(color: Colors.transparent, child: child);
      },
      itemCount: tabs.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final tab = tabs.removeAt(oldIndex);
          tabs.insert(newIndex, tab);
        });
      },
      itemBuilder: (context, index) {
        final tab = tabs[index];
        final isActive = tab.id == activeTabId;
        final isRenaming = _renamingTabId == tab.id;

        return ReorderableDragStartListener(
          key: ValueKey(tab.id),
          index: index,
          child: GestureDetector(
            onTap: () => setState(() => activeTabId = tab.id),
            onDoubleTap: () => _startRenameTab(tab),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? DraculaColors.background : Colors.transparent,
                border: isActive
                    ? const Border(
                        top: BorderSide(color: DraculaColors.purple, width: 2),
                      )
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isRenaming)
                    SizedBox(
                      width: 90,
                      height: 24,
                      child: TextField(
                        controller: _renameController,
                        autofocus: true,
                        style: const TextStyle(
                          color: DraculaColors.foreground,
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          border: OutlineInputBorder(),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: DraculaColors.purple),
                          ),
                        ),
                        onSubmitted: (_) => _commitRename(tab),
                        onTapOutside: (_) => _commitRename(tab),
                      ),
                    )
                  else
                    Text(
                      tab.title,
                      style: TextStyle(
                        color: isActive
                            ? DraculaColors.foreground
                            : DraculaColors.comment,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(width: 8),
                  // Pane count badge
                  if (tab.terminals.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: DraculaColors.comment.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${tab.terminals.length}',
                        style: const TextStyle(
                          color: DraculaColors.comment,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => _closeTab(tab),
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.close,
                        size: 13,
                        color: DraculaColors.comment,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Empty state ---
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal,
            size: 48,
            color: DraculaColors.comment.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          const Text(
            'No open tabs',
            style: TextStyle(color: DraculaColors.comment, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            'Ctrl+T to open a new terminal',
            style: TextStyle(
              color: DraculaColors.comment.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // --- Terminal split view area ---
  Widget _buildTerminalArea(WorkspaceTab tab) {
    return MultiSplitViewTheme(
      data: MultiSplitViewThemeData(
        dividerThickness: 1,
        dividerHandleBuffer: 0,
      ),
      child: MultiSplitView(
        key: ValueKey('split_${tab.id}'),
        axis: Axis.horizontal,
        controller: tab.splitController,
        builder: (context, area) {
          final paneIndex = area.index;
          if (paneIndex >= tab.terminals.length) {
            return const SizedBox.shrink();
          }
          final instance = tab.terminals[paneIndex];
          final isFocused = tab.focusedPaneId == instance.id;

          return GestureDetector(
            onTap: () {
              setState(() {
                tab.focusedPaneId = instance.id;
              });
            },
            // Right-click context menu
            onSecondaryTapUp: (details) {
              _showPaneContextMenu(
                context,
                details.globalPosition,
                tab,
                paneIndex,
              );
            },
            child: Container(
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                border: Border.all(
                  color: isFocused
                      ? DraculaColors.purple.withValues(alpha: 0.6)
                      : DraculaColors.currentLine.withValues(alpha: 0.3),
                  width: isFocused ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    top: 28,
                    child: Container(
                      color: DraculaColors.background,
                      child: ClipRect(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: RepaintBoundary(
                            child: TerminalView(
                              key: ValueKey(instance.id),
                              instance.terminal,
                              backgroundOpacity: 0.0,
                              theme: terminalTheme,
                              hardwareKeyboardOnly:
                                  Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  DragTarget<int>(
                    onWillAcceptWithDetails: (details) {
                      return details.data != paneIndex;
                    },
                    onAcceptWithDetails: (details) {
                      _reorderPanes(tab, details.data, paneIndex);
                    },
                    builder: (context, candidateData, rejectedData) {
                      final isDropTarget = candidateData.isNotEmpty;
                      return Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: isDropTarget
                              ? DraculaColors.purple.withValues(alpha: 0.25)
                              : DraculaColors.currentLine,
                          border: Border(
                            bottom: BorderSide(
                              color: DraculaColors.currentLine.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Draggable<int>(
                              data: paneIndex,
                              dragAnchorStrategy: childDragAnchorStrategy,
                              maxSimultaneousDrags: 1,
                              feedback: Material(
                                color: Colors.transparent,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: DraculaColors.currentLine,
                                    border: Border.all(
                                      color: DraculaColors.purple,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Pane ${paneIndex + 1}',
                                    style: const TextStyle(
                                      color: DraculaColors.foreground,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                              childWhenDragging: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 14,
                                  color: DraculaColors.purple,
                                ),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 14,
                                  color: DraculaColors.comment,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'Pane ${paneIndex + 1}',
                                style: TextStyle(
                                  color: isFocused
                                      ? DraculaColors.foreground
                                      : DraculaColors.comment,
                                  fontSize: 11,
                                  fontWeight: isFocused
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: () => _closePane(tab, paneIndex),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(3),
                                child: Icon(
                                  Icons.close,
                                  size: 12,
                                  color: DraculaColors.comment,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Pane right-click context menu ---
  void _showPaneContextMenu(
    BuildContext context,
    Offset position,
    WorkspaceTab tab,
    int paneIndex,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: DraculaColors.currentLine,
      items: [
        const PopupMenuItem(
          value: 'split',
          child: Row(
            children: [
              Icon(Icons.vertical_split, size: 16, color: DraculaColors.orange),
              SizedBox(width: 8),
              Text(
                'Split pane',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
              Spacer(),
              Text(
                'Ctrl+D',
                style: TextStyle(color: DraculaColors.comment, fontSize: 11),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16, color: DraculaColors.yellow),
              SizedBox(width: 8),
              Text(
                'Split in folder…',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
              Spacer(),
              Text(
                'Ctrl+Shift+D',
                style: TextStyle(color: DraculaColors.comment, fontSize: 11),
              ),
            ],
          ),
        ),
        if (tab.terminals.length > 1)
          const PopupMenuItem(
            value: 'close',
            child: Row(
              children: [
                Icon(Icons.close, size: 16, color: DraculaColors.red),
                SizedBox(width: 8),
                Text(
                  'Close pane',
                  style: TextStyle(
                    color: DraculaColors.foreground,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
      ],
    ).then((value) {
      if (value == 'split') {
        _splitPane(tab);
      } else if (value == 'split_folder') {
        _pickFolderForPane(tab);
      } else if (value == 'close') {
        _closePane(tab, paneIndex);
      }
    });
  }
}
