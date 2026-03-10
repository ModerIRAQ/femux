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
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const _prefDefaultShell = 'defaultShell';
const _prefWindowMaximized = 'windowMaximized';
const _prefLastNotifiedUpdateTag = 'lastNotifiedUpdateTag';
const _repoOwner = 'ModerIRAQ';
const _repoName = 'femux';
const _terminalMaxLines = 3000;
const _terminalReflowEnabled = false;

class UpdateCheckResult {
  final Version currentVersion;
  final Version latestVersion;
  final String latestTag;
  final String? downloadUrl;
  final String? releasePageUrl;
  final String installerLabel;

  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.latestTag,
    required this.downloadUrl,
    required this.releasePageUrl,
    required this.installerLabel,
  });

  bool get updateAvailable => latestVersion > currentVersion;
  bool get hasInstaller => downloadUrl != null;
}

class _ShellLaunchConfig {
  final String selectedShell;
  final String executable;
  final List<String> arguments;

  const _ShellLaunchConfig({
    required this.selectedShell,
    required this.executable,
    required this.arguments,
  });

  String get cacheKey => '$executable\u0000${arguments.join('\u0000')}';
}

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

String? _installerExtensionForCurrentPlatform() {
  if (Platform.isWindows) return '.exe';
  if (Platform.isLinux) return '.deb';
  if (Platform.isMacOS) return '.dmg';
  return null;
}

String _installerLabelForCurrentPlatform() {
  if (Platform.isWindows) return 'Windows installer (.exe)';
  if (Platform.isLinux) return 'Linux package (.deb)';
  if (Platform.isMacOS) return 'macOS installer (.dmg)';
  return 'installer';
}

Version _parseReleaseVersion(String rawVersion) {
  final normalized = rawVersion.trim().replaceFirst(RegExp(r'^[vV]'), '');
  return Version.parse(normalized);
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
    backgroundColor: Color(0xFF282a36),
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
  factory TerminalInstance.spawn(
    String shellPath, {
    String? workingDirectory,
    String? executableOverride,
    List<String>? argumentsOverride,
  }) {
    final executable = executableOverride ?? shellPath;
    final shellArgs = argumentsOverride ?? _shellArguments(shellPath);
    final shellEnvironment = _shellEnvironment();

    final pty = Pty.start(
      executable,
      arguments: shellArgs,
      workingDirectory: workingDirectory,
      environment: shellEnvironment,
    );

    final terminal = Terminal(
      maxLines: _terminalMaxLines,
      reflowEnabled: _terminalReflowEnabled,
    );

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

List<String> _shellArguments(String shellPath) {
  if (!Platform.isWindows) {
    return ['-l'];
  }

  final name = _shellName(shellPath);
  if (name == 'pwsh') {
    return ['-NoLogo', '-NoProfile'];
  }

  if (name == 'powershell') {
    return ['-NoLogo', '-NoProfile'];
  }

  if (name == 'cmd') {
    return ['/D', '/Q'];
  }

  return [];
}

Map<String, String>? _shellEnvironment() {
  if (!Platform.isWindows) {
    return null;
  }

  // Keep the full inherited environment so tools such as ssh can access
  // auth-agent/proxy variables that may not exist in a small allow-list.
  final result = Map<String, String>.from(Platform.environment);

  // PowerShell relies on a valid user home when initializing FileSystem drives.
  final home = result['HOME']?.trim() ?? '';
  final userProfile = result['USERPROFILE']?.trim() ?? '';
  if (home.isEmpty && userProfile.isNotEmpty) {
    result['HOME'] = userProfile;
  } else if (home.isEmpty) {
    result.remove('HOME');
  }

  // Ensure interactive CLI apps (including ssh remote shells) receive a usable TERM.
  final term = result['TERM']?.trim() ?? '';
  if (term.isEmpty) {
    result['TERM'] = 'xterm-256color';
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

_ShellLaunchConfig _directShellLaunchConfig(String shellPath) {
  final args = _shellArguments(shellPath);
  return _ShellLaunchConfig(
    selectedShell: shellPath,
    executable: shellPath,
    arguments: args,
  );
}

_ShellLaunchConfig? _cmdWrappedPowerShellLaunchConfig(String shellPath) {
  if (!Platform.isWindows) {
    return null;
  }

  final name = _shellName(shellPath);
  if (name == 'pwsh') {
    return const _ShellLaunchConfig(
      selectedShell: 'pwsh.exe',
      executable: 'cmd.exe',
      arguments: ['/D', '/Q', '/K', 'pwsh.exe -NoLogo -NoProfile'],
    );
  }

  if (name == 'powershell') {
    return const _ShellLaunchConfig(
      selectedShell: 'powershell.exe',
      executable: 'cmd.exe',
      arguments: ['/D', '/Q', '/K', 'powershell.exe -NoLogo -NoProfile'],
    );
  }

  return null;
}

List<_ShellLaunchConfig> _buildShellLaunchCandidates(String preferredShell) {
  final seen = <String>{};
  final candidates = <_ShellLaunchConfig>[];

  void addCandidate(_ShellLaunchConfig candidate) {
    if (seen.add(candidate.cacheKey)) {
      candidates.add(candidate);
    }
  }

  if (!Platform.isWindows) {
    final preferred = _resolveShellPath(preferredShell);
    addCandidate(_directShellLaunchConfig(preferred));
    addCandidate(_directShellLaunchConfig('bash'));
    return candidates;
  }

  final shells = <String>[
    _resolveShellPath(preferredShell),
    'cmd.exe',
    'pwsh.exe',
    'powershell.exe',
  ];

  for (final shell in shells) {
    final wrapped = _cmdWrappedPowerShellLaunchConfig(shell);
    if (wrapped != null) {
      addCandidate(wrapped);
      // flutter_pty on Windows can pass the PowerShell executable name as an
      // extra script argument when launched directly, producing startup errors.
      // Keep the cmd wrapper as the stable launch mode for PowerShell variants.
      continue;
    }
    addCandidate(_directShellLaunchConfig(shell));
  }

  return candidates;
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
  final Map<String, TerminalInstance> panes;
  PaneNode rootPane;
  String? focusedPaneId;

  WorkspaceTab({
    required this.id,
    required this.title,
    required this.panes,
    required this.rootPane,
    this.focusedPaneId,
  });

  int get paneCount => panes.length;

  void dispose() {
    for (final t in panes.values) {
      t.dispose();
    }
  }
}

sealed class PaneNode {
  const PaneNode();
}

class PaneLeafNode extends PaneNode {
  final String paneId;

  const PaneLeafNode(this.paneId);
}

class PaneSplitNode extends PaneNode {
  Axis axis;
  final List<PaneNode> children;
  final MultiSplitViewController controller;

  PaneSplitNode({
    required this.axis,
    required List<PaneNode> children,
    List<Area>? areas,
  }) : children = List<PaneNode>.from(children),
       controller = MultiSplitViewController(
         areas:
             areas ??
             List<Area>.generate(children.length, (_) => Area(flex: 1)),
       );
}

enum DropSide { left, right, top, bottom }

class _PaneLocation {
  final PaneLeafNode leaf;
  final PaneSplitNode? parent;
  final int indexInParent;

  const _PaneLocation({
    required this.leaf,
    required this.parent,
    required this.indexInParent,
  });
}

// --- Main UI ---
class MainWorkspace extends StatefulWidget {
  const MainWorkspace({super.key});

  @override
  State<MainWorkspace> createState() => _MainWorkspaceState();
}

class _MainWorkspaceState extends State<MainWorkspace> with WindowListener {
  final FocusNode _keyboardFocusNode = FocusNode();
  final Map<String, FocusNode> _terminalFocusNodes = <String, FocusNode>{};

  final List<WorkspaceTab> tabs = [];
  String? activeTabId;
  String defaultShellPath = Platform.isWindows ? 'cmd.exe' : 'bash';
  String _currentVersionLabel = '...';
  Version? _currentVersion;
  UpdateCheckResult? _lastUpdateCheck;
  String? _lastUpdateError;
  bool _startupUpdateCheckTriggered = false;
  String? _dropPreviewPaneId;
  DropSide? _dropPreviewSide;
  final Set<String> _failedShellLaunches = <String>{};
  Future<void> _terminalMutationQueue = Future<void>.value();
  int _pendingUserTerminalSpawns = 0;
  TerminalInstance? _warmTerminal;
  bool _warmingTerminal = false;

  // For tab rename
  String? _renamingTabId;
  final TextEditingController _renameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadSettings();
    _loadCurrentAppVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_addNewTab());
      // Keep startup path focused on terminal responsiveness.
      Future<void>.delayed(const Duration(seconds: 6), _runStartupUpdateCheck);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _keyboardFocusNode.dispose();
    for (final node in _terminalFocusNodes.values) {
      node.dispose();
    }
    _renameController.dispose();
    _disposeWarmTerminal();
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
      if (!mounted) {
        return;
      }
      _focusActivePane();
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
    final shellChanged = resolved != defaultShellPath;

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

    if (shellChanged) {
      _failedShellLaunches.clear();
      _disposeWarmTerminal();
      _ensureWarmTerminal();
    }
  }

  Future<void> _saveDefaultShell(String shell) async {
    final shellChanged = shell != defaultShellPath;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDefaultShell, shell);
    if (!mounted) return;
    setState(() {
      defaultShellPath = shell;
    });
    if (shellChanged) {
      _failedShellLaunches.clear();
      _disposeWarmTerminal();
      _ensureWarmTerminal();
    }
  }

  Future<void> _saveWindowMaximized(bool isMaximized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefWindowMaximized, isMaximized);
  }

  Future<Version> _resolveCurrentVersion() async {
    if (_currentVersion != null) {
      return _currentVersion!;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final parsed = _parseReleaseVersion(packageInfo.version);
    if (mounted) {
      setState(() {
        _currentVersion = parsed;
        _currentVersionLabel = parsed.toString();
      });
    } else {
      _currentVersion = parsed;
      _currentVersionLabel = parsed.toString();
    }
    return parsed;
  }

  Future<void> _loadCurrentAppVersion() async {
    try {
      await _resolveCurrentVersion();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _currentVersion = null;
        _currentVersionLabel = 'unknown';
      });
    }
  }

  Future<UpdateCheckResult> _fetchLatestUpdateInfo() async {
    final installerExtension = _installerExtensionForCurrentPlatform();
    if (installerExtension == null) {
      throw StateError(
        'Auto-update download is not supported on ${Platform.operatingSystem}.',
      );
    }

    final currentVersion = await _resolveCurrentVersion();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(
        Uri.https(
          'api.github.com',
          '/repos/$_repoOwner/$_repoName/releases/latest',
        ),
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'Femux Update Checker');

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('GitHub API returned HTTP ${response.statusCode}.');
      }

      final payload = jsonDecode(body);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response structure.');
      }

      final tag = (payload['tag_name']?.toString() ?? '').trim();
      if (tag.isEmpty) {
        throw const FormatException('Latest release tag is missing.');
      }

      final latestVersion = _parseReleaseVersion(tag);
      final releasePageUrl = payload['html_url']?.toString();
      String? installerUrl;

      final assets = payload['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is! Map) continue;
          final name = item['name']?.toString().toLowerCase();
          final url = item['browser_download_url']?.toString();
          if (name == null || url == null) continue;
          if (name.endsWith(installerExtension)) {
            installerUrl = url;
            break;
          }
        }
      }

      return UpdateCheckResult(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        latestTag: tag,
        downloadUrl: installerUrl,
        releasePageUrl: releasePageUrl,
        installerLabel: _installerLabelForCurrentPlatform(),
      );
    } on FormatException catch (error) {
      throw StateError('Invalid release metadata: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _openUpdateDownload(UpdateCheckResult result) async {
    final target = result.downloadUrl ?? result.releasePageUrl;
    if (target == null || target.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No download URL found for this release.'),
        ),
      );
      return;
    }

    final uri = Uri.tryParse(target);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid download URL: $target')));
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open: $target')));
    }
  }

  Future<void> _runStartupUpdateCheck() async {
    if (_startupUpdateCheckTriggered) return;
    _startupUpdateCheckTriggered = true;

    try {
      final result = await _fetchLatestUpdateInfo();
      if (!mounted) return;

      setState(() {
        _lastUpdateCheck = result;
        _lastUpdateError = null;
      });

      if (!result.updateAvailable) return;

      final prefs = await SharedPreferences.getInstance();
      final lastNotifiedTag = prefs.getString(_prefLastNotifiedUpdateTag);
      if (lastNotifiedTag == result.latestTag) return;
      await prefs.setString(_prefLastNotifiedUpdateTag, result.latestTag);

      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Update ${result.latestTag} is available.'),
          duration: const Duration(seconds: 8),
          action: result.downloadUrl != null || result.releasePageUrl != null
              ? SnackBarAction(
                  label: result.downloadUrl != null ? 'Download' : 'View',
                  onPressed: () {
                    _openUpdateDownload(result);
                  },
                )
              : null,
        ),
      );
    } catch (_) {
      // Startup check is best-effort; avoid noisy errors during launch.
    }
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
    UpdateCheckResult? updateResult = _lastUpdateCheck;
    String? updateError = _lastUpdateError;
    bool checkingUpdate = false;

    Future<void> runUpdateCheck(
      StateSetter setDialogState,
      BuildContext dialogContext,
    ) async {
      setDialogState(() {
        checkingUpdate = true;
        updateError = null;
      });

      try {
        final result = await _fetchLatestUpdateInfo();
        if (!mounted || !dialogContext.mounted) return;
        setState(() {
          _lastUpdateCheck = result;
          _lastUpdateError = null;
        });
        setDialogState(() {
          updateResult = result;
        });
      } catch (error) {
        final message = error is StateError
            ? error.message
            : 'Failed to check updates: $error';
        if (!mounted || !dialogContext.mounted) return;
        setState(() {
          _lastUpdateCheck = null;
          _lastUpdateError = message;
        });
        setDialogState(() {
          updateResult = null;
          updateError = message;
        });
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() {
            checkingUpdate = false;
          });
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final canDownloadInstaller =
                updateResult != null &&
                updateResult!.updateAvailable &&
                updateResult!.hasInstaller;
            final canOpenReleasePage =
                updateResult != null &&
                updateResult!.updateAvailable &&
                !updateResult!.hasInstaller &&
                updateResult!.releasePageUrl != null;

            String? statusText;
            Color? statusColor;
            if (updateResult != null) {
              if (!updateResult!.updateAvailable) {
                statusText = 'You are on the latest version.';
                statusColor = DraculaColors.green;
              } else if (updateResult!.hasInstaller) {
                statusText =
                    'Update available: ${updateResult!.latestVersion} (${updateResult!.latestTag})';
                statusColor = DraculaColors.yellow;
              } else {
                statusText =
                    'Update found, but no ${updateResult!.installerLabel} asset is attached to the latest release.';
                statusColor = DraculaColors.orange;
              }
            }

            return AlertDialog(
              backgroundColor: DraculaColors.currentLine,
              title: const Text(
                'Settings',
                style: TextStyle(color: DraculaColors.foreground),
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
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
                      const SizedBox(height: 18),
                      Divider(
                        color: DraculaColors.comment.withValues(alpha: 0.35),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Updates',
                        style: TextStyle(
                          color: DraculaColors.cyan,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Current version: $_currentVersionLabel',
                        style: const TextStyle(
                          color: DraculaColors.foreground,
                          fontSize: 12,
                        ),
                      ),
                      if (updateResult != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Latest version: ${updateResult!.latestVersion}',
                          style: const TextStyle(
                            color: DraculaColors.foreground,
                            fontSize: 12,
                          ),
                        ),
                        if (statusText != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            statusText,
                            style: TextStyle(
                              color: statusColor ?? DraculaColors.comment,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                      if (updateError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          updateError!,
                          style: const TextStyle(
                            color: DraculaColors.red,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (checkingUpdate)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: checkingUpdate
                                ? null
                                : () => runUpdateCheck(setDialogState, context),
                            icon: const Icon(Icons.system_update_alt, size: 16),
                            label: const Text('Check for updates'),
                          ),
                          if (canDownloadInstaller)
                            ElevatedButton.icon(
                              onPressed: checkingUpdate
                                  ? null
                                  : () => _openUpdateDownload(updateResult!),
                              icon: const Icon(Icons.download, size: 16),
                              label: Text(
                                'Download ${updateResult!.installerLabel}',
                              ),
                            ),
                          if (canOpenReleasePage)
                            ElevatedButton.icon(
                              onPressed: checkingUpdate
                                  ? null
                                  : () => _openUpdateDownload(updateResult!),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: const Text('Open release page'),
                            ),
                        ],
                      ),
                    ],
                  ),
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
                  _helpRow('Ctrl+D', 'Split active pane right (side-by-side)'),
                  _helpRow('Ctrl+Shift+D', 'Split right and choose a folder'),
                  _helpRow('Ctrl+E', 'Split active pane down (up/down)'),
                  _helpRow('Ctrl+Shift+E', 'Split down and choose a folder'),
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
                  _helpRow(
                    'Drag pane handle',
                    'Drop on pane edge to place left/right/up/down',
                  ),
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
                  _helpRow(
                    'Split right button',
                    'Create a side-by-side pane quickly',
                  ),
                  _helpRow(
                    'Split down button',
                    'Create an up/down pane quickly',
                  ),
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

  void _disposeWarmTerminal() {
    _warmTerminal?.dispose();
    _warmTerminal = null;
  }

  Future<void> _enqueueTerminalMutation(Future<void> Function() action) {
    _terminalMutationQueue = _terminalMutationQueue
        .then((_) async {
          if (!mounted) {
            return;
          }
          await action();
        })
        .catchError((_) {
          // Keep the queue alive after failures.
        });
    return _terminalMutationQueue;
  }

  void _setPendingUserTerminalSpawns(int delta) {
    final next = (_pendingUserTerminalSpawns + delta).clamp(0, 1 << 30).toInt();
    if (next == _pendingUserTerminalSpawns) {
      return;
    }
    if (!mounted) {
      _pendingUserTerminalSpawns = next;
      return;
    }
    setState(() {
      _pendingUserTerminalSpawns = next;
    });
  }

  TerminalInstance? _startTerminalInstance({
    String? workingDirectory,
    required String failureMessage,
    bool showFailureMessage = true,
  }) {
    TerminalInstance? instance;
    final shellCandidates = _buildShellLaunchCandidates(defaultShellPath);

    for (final shell in shellCandidates) {
      if (_failedShellLaunches.contains(shell.cacheKey)) {
        continue;
      }
      try {
        instance = TerminalInstance.spawn(
          shell.selectedShell,
          workingDirectory: workingDirectory,
          executableOverride: shell.executable,
          argumentsOverride: shell.arguments,
        );
        _failedShellLaunches.remove(shell.cacheKey);
        defaultShellPath = shell.selectedShell;
        break;
      } catch (_) {
        _failedShellLaunches.add(shell.cacheKey);
        continue;
      }
    }

    if (instance == null && mounted && showFailureMessage) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failureMessage)));
    }
    return instance;
  }

  Future<TerminalInstance?> _startTerminalInstanceAsync({
    String? workingDirectory,
    required String failureMessage,
    bool showFailureMessage = true,
    bool trackBusy = false,
  }) async {
    if (trackBusy) {
      _setPendingUserTerminalSpawns(1);
      // Yield once so progress UI paints before any native spawn work.
      await Future<void>.delayed(Duration.zero);
    }

    try {
      return _startTerminalInstance(
        workingDirectory: workingDirectory,
        failureMessage: failureMessage,
        showFailureMessage: showFailureMessage,
      );
    } finally {
      if (trackBusy) {
        _setPendingUserTerminalSpawns(-1);
      }
    }
  }

  void _ensureWarmTerminal() {
    if (!mounted || _warmingTerminal || _warmTerminal != null) {
      return;
    }

    if (_pendingUserTerminalSpawns > 0) {
      Future<void>.delayed(
        const Duration(milliseconds: 350),
        _ensureWarmTerminal,
      );
      return;
    }

    _warmingTerminal = true;
    Future<void>.delayed(const Duration(milliseconds: 200), () async {
      if (!mounted || _warmTerminal != null) {
        _warmingTerminal = false;
        return;
      }

      final warmed = await _startTerminalInstanceAsync(
        failureMessage: 'Unable to pre-warm terminal.',
        showFailureMessage: false,
      );

      if (!mounted) {
        warmed?.dispose();
        _warmingTerminal = false;
        return;
      }

      if (_warmTerminal == null) {
        _warmTerminal = warmed;
      } else {
        warmed?.dispose();
      }
      _warmingTerminal = false;
    });
  }

  Future<TerminalInstance?> _takeOrSpawnTerminalInstance({
    String? workingDirectory,
    required String failureMessage,
    bool trackBusy = false,
  }) async {
    if (workingDirectory == null && _warmTerminal != null) {
      final ready = _warmTerminal!;
      _warmTerminal = null;
      _ensureWarmTerminal();
      return ready;
    }

    final spawned = await _startTerminalInstanceAsync(
      workingDirectory: workingDirectory,
      failureMessage: failureMessage,
      trackBusy: trackBusy,
    );

    if (workingDirectory == null) {
      _ensureWarmTerminal();
    }

    return spawned;
  }

  List<String> _collectPaneIds(PaneNode node) {
    if (node is PaneLeafNode) {
      return [node.paneId];
    }

    final split = node as PaneSplitNode;
    final result = <String>[];
    for (final child in split.children) {
      result.addAll(_collectPaneIds(child));
    }
    return result;
  }

  _PaneLocation? _findPaneLocation(
    PaneNode node,
    String paneId, {
    PaneSplitNode? parent,
    int indexInParent = -1,
  }) {
    if (node is PaneLeafNode) {
      if (node.paneId != paneId) {
        return null;
      }
      return _PaneLocation(
        leaf: node,
        parent: parent,
        indexInParent: indexInParent,
      );
    }

    final split = node as PaneSplitNode;
    for (var i = 0; i < split.children.length; i++) {
      final found = _findPaneLocation(
        split.children[i],
        paneId,
        parent: split,
        indexInParent: i,
      );
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  Area _copyAreaWithFallback(Area? source) {
    if (source == null) {
      return Area(flex: 1);
    }
    return Area(
      size: source.size,
      flex: source.size == null ? source.flex : null,
      min: source.min,
      max: source.max,
    );
  }

  void _insertAreaAt(PaneSplitNode split, int index) {
    final areas = split.controller.areas.toList(growable: true);
    final safeIndex = index.clamp(0, areas.length).toInt();
    areas.insert(safeIndex, Area(flex: 1));
    split.controller.areas = areas;
  }

  void _removeAreaAt(PaneSplitNode split, int index) {
    final areas = split.controller.areas.toList(growable: true);
    if (index >= 0 && index < areas.length) {
      areas.removeAt(index);
    }
    if (areas.isEmpty) {
      areas.add(Area(flex: 1));
    }
    split.controller.areas = areas;
  }

  void _syncSplitTree(PaneNode node) {
    if (node is! PaneSplitNode) {
      return;
    }

    final current = node.controller.areas.toList(growable: false);
    if (current.length != node.children.length) {
      final synced = <Area>[];
      for (var i = 0; i < node.children.length; i++) {
        synced.add(
          _copyAreaWithFallback(i < current.length ? current[i] : null),
        );
      }
      node.controller.areas = synced;
    }

    for (final child in node.children) {
      _syncSplitTree(child);
    }
  }

  PaneNode _normalizePaneTree(PaneNode node) {
    if (node is! PaneSplitNode) {
      return node;
    }

    for (var i = 0; i < node.children.length; i++) {
      node.children[i] = _normalizePaneTree(node.children[i]);
    }

    if (node.children.length == 1) {
      return node.children.first;
    }

    _syncSplitTree(node);
    return node;
  }

  void _replacePaneNode(WorkspaceTab tab, String paneId, PaneNode replacement) {
    final location = _findPaneLocation(tab.rootPane, paneId);
    if (location == null) {
      return;
    }

    if (location.parent == null) {
      tab.rootPane = replacement;
    } else {
      location.parent!.children[location.indexInParent] = replacement;
      _syncSplitTree(location.parent!);
    }
  }

  PaneLeafNode? _detachPane(WorkspaceTab tab, String paneId) {
    final location = _findPaneLocation(tab.rootPane, paneId);
    if (location == null || location.parent == null) {
      return null;
    }

    location.parent!.children.removeAt(location.indexInParent);
    _removeAreaAt(location.parent!, location.indexInParent);
    tab.rootPane = _normalizePaneTree(tab.rootPane);
    return location.leaf;
  }

  void _insertLeafRelativeToTarget(
    WorkspaceTab tab, {
    required PaneLeafNode leafToInsert,
    required String targetPaneId,
    required DropSide side,
  }) {
    final targetLocation = _findPaneLocation(tab.rootPane, targetPaneId);
    if (targetLocation == null) {
      tab.rootPane = PaneSplitNode(
        axis: Axis.horizontal,
        children: [tab.rootPane, leafToInsert],
      );
      tab.rootPane = _normalizePaneTree(tab.rootPane);
      return;
    }

    final axis = side == DropSide.left || side == DropSide.right
        ? Axis.horizontal
        : Axis.vertical;
    final insertAfter = side == DropSide.right || side == DropSide.bottom;

    final parent = targetLocation.parent;
    if (parent != null && parent.axis == axis) {
      final insertIndex = targetLocation.indexInParent + (insertAfter ? 1 : 0);
      parent.children.insert(insertIndex, leafToInsert);
      _insertAreaAt(parent, insertIndex);
      tab.rootPane = _normalizePaneTree(tab.rootPane);
      return;
    }

    final replacement = PaneSplitNode(
      axis: axis,
      children: insertAfter
          ? [targetLocation.leaf, leafToInsert]
          : [leafToInsert, targetLocation.leaf],
    );
    _replacePaneNode(tab, targetPaneId, replacement);
    tab.rootPane = _normalizePaneTree(tab.rootPane);
  }

  void _movePaneByDrop(
    WorkspaceTab tab, {
    required String draggedPaneId,
    required String targetPaneId,
    required DropSide side,
  }) {
    if (draggedPaneId == targetPaneId) {
      return;
    }

    final movingLeaf = _detachPane(tab, draggedPaneId);
    if (movingLeaf == null) {
      return;
    }

    if (_findPaneLocation(tab.rootPane, targetPaneId) == null) {
      final firstPaneId = _collectPaneIds(tab.rootPane).firstOrNull;
      if (firstPaneId != null) {
        _insertLeafRelativeToTarget(
          tab,
          leafToInsert: movingLeaf,
          targetPaneId: firstPaneId,
          side: DropSide.right,
        );
      }
    } else {
      _insertLeafRelativeToTarget(
        tab,
        leafToInsert: movingLeaf,
        targetPaneId: targetPaneId,
        side: side,
      );
    }

    tab.focusedPaneId = draggedPaneId;
    setState(() {});
  }

  Future<void> _addNewTab({String? workingDirectory}) {
    return _enqueueTerminalMutation(() async {
      final instance = await _takeOrSpawnTerminalInstance(
        workingDirectory: workingDirectory,
        failureMessage: 'Unable to start a shell (pwsh/powershell/cmd).',
        trackBusy: true,
      );
      if (instance == null) {
        return;
      }

      if (!mounted) {
        instance.dispose();
        return;
      }

      final root = PaneLeafNode(instance.id);
      final newTab = WorkspaceTab(
        id: UniqueKey().toString(),
        title: workingDirectory != null
            ? workingDirectory.split(Platform.pathSeparator).last
            : 'Terminal',
        panes: {instance.id: instance},
        rootPane: root,
        focusedPaneId: instance.id,
      );

      setState(() {
        tabs.add(newTab);
        activeTabId = newTab.id;
      });
      _focusPaneSoon(instance.id);
    });
  }

  Future<void> _splitPane(
    WorkspaceTab tab, {
    String? workingDirectory,
    DropSide side = DropSide.right,
    String? targetPaneId,
  }) {
    return _enqueueTerminalMutation(() async {
      if (!mounted || !tabs.contains(tab)) {
        return;
      }

      final instance = await _takeOrSpawnTerminalInstance(
        workingDirectory: workingDirectory,
        failureMessage: 'Unable to split pane: no shell could be started.',
        trackBusy: true,
      );
      if (instance == null) {
        return;
      }

      if (!mounted || !tabs.contains(tab)) {
        instance.dispose();
        return;
      }

      final targetId =
          targetPaneId ??
          tab.focusedPaneId ??
          _collectPaneIds(tab.rootPane).firstOrNull;
      if (targetId == null) {
        instance.dispose();
        return;
      }

      tab.panes[instance.id] = instance;
      _insertLeafRelativeToTarget(
        tab,
        leafToInsert: PaneLeafNode(instance.id),
        targetPaneId: targetId,
        side: side,
      );
      tab.focusedPaneId = instance.id;
      setState(() {});
      _focusPaneSoon(instance.id);
    });
  }

  void _closePane(WorkspaceTab tab, String paneId) {
    if (tab.paneCount <= 1) {
      _closeTab(tab);
      return;
    }

    final removed = _detachPane(tab, paneId);
    if (removed == null) {
      return;
    }

    final instance = tab.panes.remove(paneId);
    instance?.dispose();
    _disposeFocusNodeForPane(paneId);

    if (tab.focusedPaneId == paneId) {
      tab.focusedPaneId = _collectPaneIds(tab.rootPane).firstOrNull;
    }
    setState(() {});
    _focusActivePane();
  }

  void _closeTab(WorkspaceTab tab) {
    for (final paneId in tab.panes.keys) {
      _disposeFocusNodeForPane(paneId);
    }
    tab.dispose();
    setState(() {
      tabs.remove(tab);
      if (activeTabId == tab.id) {
        activeTabId = tabs.isNotEmpty ? tabs.last.id : null;
      }
    });
    _focusActivePane();
  }

  Future<void> _pickFolderForPane(
    WorkspaceTab tab, {
    DropSide side = DropSide.right,
    String? targetPaneId,
  }) async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      unawaited(
        _splitPane(
          tab,
          workingDirectory: dir,
          side: side,
          targetPaneId: targetPaneId,
        ),
      );
    }
  }

  WorkspaceTab? get _activeTab {
    if (activeTabId == null) return null;
    final id = activeTabId;
    for (final tab in tabs) {
      if (tab.id == id) {
        return tab;
      }
    }
    return null;
  }

  FocusNode _focusNodeForPane(String paneId) {
    return _terminalFocusNodes.putIfAbsent(
      paneId,
      () => FocusNode(debugLabel: 'terminal:$paneId'),
    );
  }

  void _disposeFocusNodeForPane(String paneId) {
    _terminalFocusNodes.remove(paneId)?.dispose();
  }

  void _focusPaneSoon(String paneId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final node = _terminalFocusNodes[paneId];
      if (node == null || !node.canRequestFocus) {
        _keyboardFocusNode.requestFocus();
        return;
      }
      node.requestFocus();
    });
  }

  void _focusActivePane() {
    final paneId = _activeTab?.focusedPaneId;
    if (paneId == null) {
      _keyboardFocusNode.requestFocus();
      return;
    }
    _focusPaneSoon(paneId);
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
      unawaited(_addNewTab());
      return KeyEventResult.handled;
    }

    // Ctrl+W → close active tab
    if (ctrl && key == LogicalKeyboardKey.keyW) {
      final tab = _activeTab;
      if (tab != null) _closeTab(tab);
      return KeyEventResult.handled;
    }

    // Ctrl+D → split pane right (side-by-side)
    if (ctrl && !shift && key == LogicalKeyboardKey.keyD) {
      final tab = _activeTab;
      if (tab != null) {
        unawaited(_splitPane(tab, side: DropSide.right));
      }
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+D → split right with folder picker
    if (ctrl && shift && key == LogicalKeyboardKey.keyD) {
      final tab = _activeTab;
      if (tab != null) {
        unawaited(_pickFolderForPane(tab, side: DropSide.right));
      }
      return KeyEventResult.handled;
    }

    // Ctrl+E → split pane down (up/down)
    if (ctrl && !shift && key == LogicalKeyboardKey.keyE) {
      final tab = _activeTab;
      if (tab != null) {
        unawaited(_splitPane(tab, side: DropSide.bottom));
      }
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+E → split down with folder picker
    if (ctrl && shift && key == LogicalKeyboardKey.keyE) {
      final tab = _activeTab;
      if (tab != null) {
        unawaited(_pickFolderForPane(tab, side: DropSide.bottom));
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // --- Build ---
  @override
  Widget build(BuildContext context) {
    final activeTab = _activeTab;

    return Scaffold(
      body: Stack(
        children: [
          Focus(
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
          if (_pendingUserTerminalSpawns > 0)
            const Positioned(
              top: 40,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
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

            // Split right (side-by-side)
            _titleBarIconButton(
              icon: Icons.vertical_split,
              tooltip:
                  'Split right (Ctrl+D) · Split right in folder (Ctrl+Shift+D)',
              color: DraculaColors.orange,
              onTap: () {
                final tab = _activeTab;
                if (tab != null) {
                  unawaited(_splitPane(tab, side: DropSide.right));
                }
              },
            ),

            // Split down (up/down)
            _titleBarIconButton(
              icon: Icons.view_agenda,
              tooltip:
                  'Split down (Ctrl+E) · Split down in folder (Ctrl+Shift+E)',
              color: DraculaColors.cyan,
              onTap: () {
                final tab = _activeTab;
                if (tab != null) {
                  unawaited(_splitPane(tab, side: DropSide.bottom));
                }
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
      itemCount: tabs.length + 1,
      onReorder: (oldIndex, newIndex) {
        if (oldIndex < 0 || oldIndex >= tabs.length) return;
        setState(() {
          // Keep the "+" button fixed as the trailing element.
          if (newIndex > tabs.length) {
            newIndex = tabs.length;
          }
          if (newIndex > oldIndex) newIndex--;
          if (newIndex < 0) newIndex = 0;
          if (newIndex > tabs.length - 1) newIndex = tabs.length - 1;
          final tab = tabs.removeAt(oldIndex);
          tabs.insert(newIndex, tab);
        });
      },
      itemBuilder: (context, index) {
        if (index == tabs.length) {
          return Container(
            key: const ValueKey('new-tab-button'),
            alignment: Alignment.center,
            child: Tooltip(
              message: 'New tab · Long-press to pick folder',
              child: GestureDetector(
                onTap: () => unawaited(_addNewTab()),
                onLongPress: () async {
                  final dir = await FilePicker.platform.getDirectoryPath();
                  if (dir != null) {
                    unawaited(_addNewTab(workingDirectory: dir));
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.add, color: DraculaColors.green, size: 18),
                ),
              ),
            ),
          );
        }

        final tab = tabs[index];
        final isActive = tab.id == activeTabId;
        final isRenaming = _renamingTabId == tab.id;

        return ReorderableDragStartListener(
          key: ValueKey(tab.id),
          index: index,
          child: GestureDetector(
            onTap: () {
              setState(() => activeTabId = tab.id);
              _focusActivePane();
            },
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
                  if (tab.paneCount > 1)
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
                        '${tab.paneCount}',
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
    _syncSplitTree(tab.rootPane);
    final paneOrderIds = _collectPaneIds(tab.rootPane);
    final paneOrder = <String, int>{
      for (var i = 0; i < paneOrderIds.length; i++) paneOrderIds[i]: i + 1,
    };

    return MultiSplitViewTheme(
      data: MultiSplitViewThemeData(
        dividerThickness: 1,
        dividerHandleBuffer: 0,
      ),
      child: _buildPaneNode(tab, tab.rootPane, paneOrder),
    );
  }

  Widget _buildPaneNode(
    WorkspaceTab tab,
    PaneNode node,
    Map<String, int> paneOrder,
  ) {
    if (node is PaneLeafNode) {
      final instance = tab.panes[node.paneId];
      if (instance == null) {
        return const SizedBox.shrink();
      }
      return _buildPaneLeaf(tab, instance, paneOrder[node.paneId] ?? 1);
    }

    final split = node as PaneSplitNode;
    return MultiSplitView(
      axis: split.axis,
      controller: split.controller,
      builder: (context, area) {
        if (area.index >= split.children.length) {
          return const SizedBox.shrink();
        }
        return _buildPaneNode(tab, split.children[area.index], paneOrder);
      },
    );
  }

  DropSide _resolveDropSide(BuildContext context, Offset globalOffset) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox) {
      return DropSide.right;
    }

    final local = renderBox.globalToLocal(globalOffset);
    final size = renderBox.size;
    final dx = local.dx - (size.width / 2);
    final dy = local.dy - (size.height / 2);

    if (dx.abs() > dy.abs()) {
      return dx < 0 ? DropSide.left : DropSide.right;
    }
    return dy < 0 ? DropSide.top : DropSide.bottom;
  }

  Widget _buildDropSideOverlay(DropSide side) {
    const thickness = 4.0;
    final color = DraculaColors.cyan.withValues(alpha: 0.9);

    switch (side) {
      case DropSide.left:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(width: thickness, color: color),
        );
      case DropSide.right:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(width: thickness, color: color),
        );
      case DropSide.top:
        return Align(
          alignment: Alignment.topCenter,
          child: Container(height: thickness, color: color),
        );
      case DropSide.bottom:
        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(height: thickness, color: color),
        );
    }
  }

  Widget _buildPaneLeaf(
    WorkspaceTab tab,
    TerminalInstance instance,
    int paneNo,
  ) {
    final paneId = instance.id;
    final isFocused = tab.focusedPaneId == paneId;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (tab.focusedPaneId == paneId && tab.id == activeTabId) {
          _focusPaneSoon(paneId);
          return;
        }
        setState(() {
          activeTabId = tab.id;
          tab.focusedPaneId = paneId;
        });
        _focusPaneSoon(paneId);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) {
          unawaited(
            _showPaneContextMenu(context, details.globalPosition, tab, paneId),
          );
        },
        child: DragTarget<String>(
          onWillAcceptWithDetails: (details) => details.data != paneId,
          onMove: (details) {
            final side = _resolveDropSide(context, details.offset);
            if (_dropPreviewPaneId == paneId && _dropPreviewSide == side) {
              return;
            }
            setState(() {
              _dropPreviewPaneId = paneId;
              _dropPreviewSide = side;
            });
          },
          onLeave: (_) {
            if (_dropPreviewPaneId != paneId) {
              return;
            }
            setState(() {
              _dropPreviewPaneId = null;
              _dropPreviewSide = null;
            });
          },
          onAcceptWithDetails: (details) {
            final side = _resolveDropSide(context, details.offset);
            setState(() {
              _dropPreviewPaneId = null;
              _dropPreviewSide = null;
            });
            _movePaneByDrop(
              tab,
              draggedPaneId: details.data,
              targetPaneId: paneId,
              side: side,
            );
          },
          builder: (context, candidateData, rejectedData) {
            final hasCandidate = candidateData.isNotEmpty;
            final showPreview =
                _dropPreviewPaneId == paneId && _dropPreviewSide != null;

            return Container(
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
                              key: ValueKey('terminal-view-$paneId'),
                              instance.terminal,
                              // Keep the terminal renderer opaque so ANSI clear
                              // sequences repaint the full surface instead of
                              // leaving stale pixels in the retained layer.
                              backgroundOpacity: 1.0,
                              focusNode: _focusNodeForPane(paneId),
                              autofocus: isFocused && tab.id == activeTabId,
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
                  Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: hasCandidate
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
                        Draggable<String>(
                          data: paneId,
                          dragAnchorStrategy: childDragAnchorStrategy,
                          maxSimultaneousDrags: 1,
                          onDragEnd: (_) {
                            if (_dropPreviewPaneId == null &&
                                _dropPreviewSide == null) {
                              return;
                            }
                            setState(() {
                              _dropPreviewPaneId = null;
                              _dropPreviewSide = null;
                            });
                          },
                          feedback: Material(
                            color: Colors.transparent,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: DraculaColors.currentLine,
                                border: Border.all(color: DraculaColors.purple),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Pane $paneNo',
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
                            'Pane $paneNo',
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
                          onTap: () => _closePane(tab, paneId),
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
                  ),
                  if (showPreview) _buildDropSideOverlay(_dropPreviewSide!),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Pane right-click context menu ---
  Future<void> _showPaneContextMenu(
    BuildContext context,
    Offset position,
    WorkspaceTab tab,
    String paneId,
  ) async {
    // Yield one microtask so pointer handling can complete before route push.
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !context.mounted || !tabs.contains(tab)) {
      return;
    }

    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: DraculaColors.currentLine,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        const PopupMenuItem(
          value: 'split_right',
          child: Row(
            children: [
              Icon(Icons.vertical_split, size: 16, color: DraculaColors.orange),
              SizedBox(width: 8),
              Text(
                'Split right',
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
          value: 'split_left',
          child: Row(
            children: [
              Icon(Icons.vertical_split, size: 16, color: DraculaColors.orange),
              SizedBox(width: 8),
              Text(
                'Split left',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_left_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16, color: DraculaColors.yellow),
              SizedBox(width: 8),
              Text(
                'Split left in folder…',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_right_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16, color: DraculaColors.yellow),
              SizedBox(width: 8),
              Text(
                'Split right in folder…',
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
        const PopupMenuItem(
          value: 'split_down',
          child: Row(
            children: [
              Icon(Icons.view_agenda, size: 16, color: DraculaColors.cyan),
              SizedBox(width: 8),
              Text(
                'Split down',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
              Spacer(),
              Text(
                'Ctrl+E',
                style: TextStyle(color: DraculaColors.comment, fontSize: 11),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_up',
          child: Row(
            children: [
              Icon(Icons.view_agenda, size: 16, color: DraculaColors.cyan),
              SizedBox(width: 8),
              Text(
                'Split up',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_up_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16, color: DraculaColors.cyan),
              SizedBox(width: 8),
              Text(
                'Split up in folder…',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'split_down_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16, color: DraculaColors.cyan),
              SizedBox(width: 8),
              Text(
                'Split down in folder…',
                style: TextStyle(color: DraculaColors.foreground, fontSize: 13),
              ),
              Spacer(),
              Text(
                'Ctrl+Shift+E',
                style: TextStyle(color: DraculaColors.comment, fontSize: 11),
              ),
            ],
          ),
        ),
        if (tab.paneCount > 1)
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
    );

    if (!mounted || !tabs.contains(tab) || value == null) {
      return;
    }

    // Let the popup route removal paint before terminal spawn work begins.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !tabs.contains(tab)) {
      return;
    }

    if (value == 'split_right') {
      unawaited(_splitPane(tab, side: DropSide.right, targetPaneId: paneId));
    } else if (value == 'split_left') {
      unawaited(_splitPane(tab, side: DropSide.left, targetPaneId: paneId));
    } else if (value == 'split_left_folder') {
      unawaited(
        _pickFolderForPane(tab, side: DropSide.left, targetPaneId: paneId),
      );
    } else if (value == 'split_right_folder') {
      unawaited(
        _pickFolderForPane(tab, side: DropSide.right, targetPaneId: paneId),
      );
    } else if (value == 'split_down') {
      unawaited(_splitPane(tab, side: DropSide.bottom, targetPaneId: paneId));
    } else if (value == 'split_up') {
      unawaited(_splitPane(tab, side: DropSide.top, targetPaneId: paneId));
    } else if (value == 'split_up_folder') {
      unawaited(
        _pickFolderForPane(tab, side: DropSide.top, targetPaneId: paneId),
      );
    } else if (value == 'split_down_folder') {
      unawaited(
        _pickFolderForPane(tab, side: DropSide.bottom, targetPaneId: paneId),
      );
    } else if (value == 'close') {
      _closePane(tab, paneId);
    }
  }
}
