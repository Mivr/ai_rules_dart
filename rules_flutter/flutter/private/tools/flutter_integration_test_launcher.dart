/// Shared platform-launcher interface for `flutter_integration_test`.
///
/// Imported by the runner harness and by each platform launcher, so no
/// platform launcher ever imports the runner's main library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'test_support.dart';

/// WebSocket upgrade path the in-app bootstrap dials on the harness server.
///
/// The run's token travels as its `token` query parameter; a dial-back
/// without this run's token is refused and never adopted.
const String integrationWebSocketPath = '/__flutter_integration_ws__';

/// Query parameter carrying the run's token on the harness WebSocket URL.
const String integrationTokenQueryParam = 'token';

/// Everything a platform launcher needs to reach this run's harness: the
/// server's loopback port plus the run's random token.
///
/// The values travel together so launchers never take a bare port (whose URL
/// would miss the token) or a bare token (whose server they could not find).
class HarnessBinding {
  const new({required this.port, required this.token});

  /// The harness HTTP/WebSocket server's loopback port.
  final int port;

  /// The run's random token; only a dial-back carrying it is adopted.
  final String token;

  /// The WebSocket URL the target dials, carrying [token] for the harness.
  String get url =>
      'ws://127.0.0.1:$port$integrationWebSocketPath?$integrationTokenQueryParam=$token';
}

/// Generates a random per-run harness token: 128 bits from [Random.secure],
/// hex-encoded.
///
/// Public, like [decodeDeclaredEnv], because the runner and its tests reach
/// it directly: the runner mints one token per run, and the tests mint fixed
/// ones for deterministic dial-backs.
String generateHarnessToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The harness token carried by [uri]'s query, or null when absent.
///
/// Public, like [decodeDeclaredEnv], because the runner's dial-back check and
/// its tests reach it directly.
String? harnessTokenOf(Uri uri) =>
    uri.queryParameters[integrationTokenQueryParam];

/// Decodes the JSON-encoded declared environment forwarded by
/// `flutter_integration_test.bzl` (`FLUTTER_INTEGRATION_TEST_DECLARED_ENV`).
/// Decodes the JSON map stored in a `*_DECLARED_ENV` launcher variable.
///
/// Public, like [buildChromeArguments], because the test reaches it
/// directly. A missing variable or a malformed payload decodes to an empty
/// map: a build that received no usable declared environment falls back to
/// inherited-environment-only resolution, and a missing variable surfaces
/// later as a concrete lookup error instead.
Map<String, String> decodeDeclaredEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, String>{};
  try {
    final dynamic decoded = json.decode(raw);
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
  } on FormatException {
    // Corrupted declared environment behaves like none at all.
  }
  return const <String, String>{};
}

/// Resolves the forwarded ambient values for the `build*Environment`
/// helpers: the declared entries (empty when nothing was forwarded) and the
/// effective timezone, where a declared `TZ` entry wins.
///
/// One helper for all three builders, so the resolution they used to copy
/// stays identical everywhere.
({Map<String, String> declared, String timeZone, String? fontconfigFile})
resolveForwarding(EnvForwarding forwarding) {
  final Map<String, String> declared =
      forwarding.env ?? const <String, String>{};
  return (
    declared: declared,
    timeZone: declared['TZ'] ?? forwarding.tz ?? 'UTC',
    fontconfigFile: forwarding.fontconfigFile,
  );
}

/// Abstraction over how a target platform starts the compiled app and serves
/// any platform-specific HTTP endpoints on the harness [HttpServer].
abstract class PlatformLauncher {
  /// Platform identifier (`'web'`, `'linux'`, `'android'`, `'ios'`).
  String get platformName;

  /// Runtime identifier for `package:test_api` `SuitePlatform`.
  String get suiteRuntime;

  /// Compiler identifier for `package:test_api` `SuitePlatform`.
  String get suiteCompiler;

  /// Handles a non-WebSocket HTTP request arriving on the harness server.
  Future<void> handleHttpRequest(HttpRequest request);

  /// Starts the target process against [binding]'s harness, dialling back
  /// over its token-carrying URL.
  Future<Process> startTarget(HarnessBinding binding);

  /// Cleans up any temporary directories created for the target process.
  Future<void> dispose();
}

/// Emulator console/adb ports and adb server port the launcher chose, plus
/// the port lines the emulator printed (`log`).
typedef DiscoveryPorts = ({int console, int adb, int server, List<String> log});

/// Liveness and namespaces of one process; each is a value or
/// `unavailable: <reason>`.
typedef ProcFacts = ({String alive, String pidNs, String netNs});

/// What [buildDiscoveryDiagnostics] prints; `tmp` is `TEST_TMPDIR`.
typedef DiscoveryFacts = ({
  String tmp,
  DiscoveryPorts ports,
  String devices,
  String dir,
  ProcFacts adb,
  ProcFacts emulator,
});

/// Live inputs of [collectDiscoveryDiagnostics].
typedef DiscoveryProbe = ({
  String adb,
  Map<String, String> env,
  String tmp,
  DiscoveryPorts ports,
  int emuPid,
});

const Duration _diagBudget = Duration(seconds: 20);

/// Whether the emulator log line [l] mentions a port.
bool isPortLine(String l) => l.toLowerCase().contains('port');

/// Formats the labelled discovery block, redacted. Pure: facts in, string out.
String buildDiscoveryDiagnostics(DiscoveryFacts f) {
  String ind(String s) => '  ${s.split('\n').join('\n  ')}';
  String proc(String n, ProcFacts p) =>
      '$n process: alive: ${p.alive}\n  pid namespace: ${p.pidNs}\n  net namespace: ${p.netNs}';
  final DiscoveryPorts p = f.ports;
  final String block = <String>[
    '--- Android emulator discovery diagnostics ---',
    'adb devices -l (hermetic adb environment):',
    ind(f.devices),
    'ports: emulator console ${p.console}, emulator adb ${p.adb}, adb server ${p.server}',
    'port lines printed by the emulator:',
    ind(p.log.isEmpty ? '(none)' : p.log.join('\n')),
    'emulator discovery directory (names, sizes, modes):',
    ind(f.dir),
    proc('adb server', f.adb),
    proc('emulator', f.emulator),
    '--- end of diagnostics ---',
  ].join('\n');
  final String scoped = f.tmp.isEmpty
      ? block
      : block.replaceAll(f.tmp, r'$TEST_TMPDIR');
  return scoped
      .replaceAll(
        RegExp(r'''(?<![\w$/.:-])/[^\s'":,;()\[\]]+'''),
        '<host-path>',
      )
      .replaceAllMapped(
        RegExp(
          r'(token|secret|passw(or)?d|auth|key)(\s*[=:]\s*)\S+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}${m[3]}<redacted>',
      );
}

/// Whether [e] is a discovery failure for [serial]: a boot timeout or adb
/// reporting `device '<serial>' not found`.
bool isDiscoveryFailure(Object e, String serial) =>
    e is TimeoutException ||
    (e is StateError && e.message.contains("device '$serial' not found"));

/// [e] rebuilt with [block] after its message, keeping its type.
Object decorateDiscoveryFailure(Object e, String block) => switch (e) {
  TimeoutException(:final message, :final duration) => TimeoutException(
    '${message ?? 'Timed out'}\n\n$block',
    duration,
  ),
  StateError(:final message) => StateError('$message\n\n$block'),
  _ => e,
};

String _unavailable(Object e) =>
    'unavailable: ${e is FileSystemException ? e.osError?.message ?? e.message : e.runtimeType}';

/// Collects the block. Never throws, never takes over 20 seconds; what cannot
/// be collected reads `unavailable: <reason>`.
Future<String> collectDiscoveryDiagnostics(DiscoveryProbe p) async {
  const head = '--- Android emulator discovery diagnostics ---\n';
  try {
    return await _collect(p).timeout(_diagBudget);
  } on TimeoutException {
    return '${head}unavailable: collection exceeded ${_diagBudget.inSeconds}s';
  }
}

Future<String> _collect(DiscoveryProbe p) async {
  final int? adbPid = _adbServerPid(p.ports.server);
  return buildDiscoveryDiagnostics((
    tmp: p.tmp,
    ports: p.ports,
    devices: await _adbDevices(p),
    dir: _listDiscoveryDirs(p.env['HOME'] ?? ''),
    adb: _procFacts(adbPid, adbPid == null ? null : _isAlive(adbPid)),
    emulator: _procFacts(p.emuPid, _isAlive(p.emuPid)),
  ));
}

bool _isAlive(int pid) => Directory('/proc/$pid').existsSync();

Future<String> _adbDevices(DiscoveryProbe p) async {
  try {
    final ProcessResult r = await Process.run(
      p.adb,
      const <String>['devices', '-l'],
      environment: p.env,
      includeParentEnvironment: false,
    ).timeout(const Duration(seconds: 5));
    return '${r.stdout}${r.stderr}'.trim();
  } on TimeoutException {
    return 'unavailable: adb devices -l timed out';
  } on IOException catch (e) {
    return _unavailable(e);
  }
}

ProcFacts _procFacts(int? pid, bool? alive) {
  const noPid = 'unavailable: process id unknown';
  String ns(String kind) {
    if (pid == null) return noPid;
    try {
      return Link('/proc/$pid/ns/$kind').targetSync();
    } on FileSystemException catch (e) {
      return _unavailable(e);
    }
  }

  return (
    alive: alive == null ? noPid : (alive ? 'yes' : 'no'),
    pidNs: ns('pid'),
    netNs: ns('net'),
  );
}

/// Lists (names, sizes, modes; never contents) the directories the emulator
/// registers itself in under the isolated `XDG_RUNTIME_DIR` and `TMPDIR`.
String _listDiscoveryDirs(String scratch) {
  try {
    return <String>[
      for (final rel in const ['xdg-runtime/avd', 'android-android/avd'])
        _listTree(Directory('$scratch/$rel')),
    ].join('\n');
  } on FileSystemException catch (e) {
    return _unavailable(e);
  }
}

String _listTree(Directory dir) {
  if (!dir.existsSync()) return '${dir.path}: directory does not exist';
  final rows = <String>[
    for (final e in dir.listSync(recursive: true, followLinks: false).take(60))
      '  ${e.path.substring(dir.path.length + 1)} ${_stat(e.statSync())}',
  ];
  return '${dir.path}:\n${rows.join('\n')}';
}

String _stat(FileStat st) =>
    '${st.size}B ${(st.mode & 0xFFF).toRadixString(8)}';

/// The pid of the `adb fork-server` for adb server [port], or null.
int? _adbServerPid(int port) {
  try {
    for (final FileSystemEntity e in Directory('/proc').listSync()) {
      final int? pid = int.tryParse(e.path.split('/').last);
      if (pid == null || !_procText(pid, 'cmdline').contains('fork-server')) {
        continue;
      }
      if (_procText(
        pid,
        'environ',
      ).contains('ANDROID_ADB_SERVER_PORT=$port\u0000')) {
        return pid;
      }
    }
  } on FileSystemException {
    return null; // no readable /proc: callers print "unavailable".
  }
  return null;
}

String _procText(int pid, String name) {
  try {
    return latin1.decode(File('/proc/$pid/$name').readAsBytesSync());
  } on FileSystemException {
    return ''; // the process exited or belongs to another user.
  }
}
