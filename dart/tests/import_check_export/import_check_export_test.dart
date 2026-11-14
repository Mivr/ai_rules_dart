import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// How the nested Bazel process is launched in `dev/`.
typedef _BazelConfig = ({
  String executable,
  bool runInShell,
  String workingDirectory,
  List<String> startupArgs,
  Map<String, String> environment,
});

/// Host filesystem callbacks used to resolve the outer Bazel binary and rc.
typedef _HostFs = ({
  bool Function(String path) fileExists,
  bool Function(String path) executableExists,
  String? Function(String path) readText,
});

const Set<String> _outerTestVars = {
  'JAVA_RUNFILES',
  'RUNFILES_DIR',
  'RUNFILES_MANIFEST_FILE',
  'RUNFILES_MANIFEST_ONLY',
  'TEST_SRCDIR',
  'TEST_TMPDIR',
  'TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR',
  'TEST_UNDECLARED_OUTPUTS_DIR',
};

final RegExp _msysDrive = RegExp(r'^/([A-Za-z])(/.*)?$');

/// Builds the nested `dev` fixtures as a consumer would.
///
/// `dev/` is a nested module that depends on rules_dart as an external
/// repository, so its rule (`defs.bzl`) loads `@rules_dart//dart:import_check.bzl`
/// and defaults `_import_check` to `//dart:import_check` from outside
/// `//dart`. A clean executable must build; one that imports a package its
/// `deps` do not provide must fail with the check's usual line. The second
/// fixture, `dev/exe_mirrors`, is a `dart_binary(compile_mode = "exe")` that
/// imports `dart:mirrors`: its build must fail with the front end's line. The
/// nested Bazel uses its own short output base, so it never waits on the outer
/// server.
void main(List<String> args) {
  final String root = _workspaceRoot(args.first);
  late final Directory scratch;
  late final _BazelConfig bazel;
  var serverStarted = false;

  ProcessResult build(List<String> targets) {
    serverStarted = true;
    return _build(bazel, targets);
  }

  setUpAll(() {
    final String parent = _scratchParent(
      Platform.environment,
      isWindows: Platform.isWindows,
      systemTempPath: Directory.systemTemp.path,
      dirExists: (path) => Directory(path).existsSync(),
    );
    scratch = Directory(parent).createTempSync('rd_ice_');
    Directory(p.join(scratch.path, 'tmp')).createSync(recursive: true);
    bazel = _prepareBazel(
      root: root,
      scratchPath: scratch.path,
      hostEnv: Platform.environment,
      fs: _realHostFs(isWindows: Platform.isWindows),
      isWindows: Platform.isWindows,
    );
  });

  tearDownAll(() {
    _cleanup(bazel, scratch, serverStarted: serverStarted);
  });

  _registerImportCheckTests(build);
  _registerExeMirrorsTest(build);
  _registerLauncherConfigTests();
}

void _registerImportCheckTests(ProcessResult Function(List<String>) build) {
  group('exported import check', () {
    test('a clean executable passes the check', () {
      final ProcessResult result = build(['//import_check_export:clean']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });

    test('an executable importing a package its deps lack fails the check', () {
      final ProcessResult result = build(['//import_check_export:bad']);
      final output = '${result.stdout}${result.stderr}';
      expect(result.exitCode, isNot(0), reason: output);
      expect(
        output,
        contains(
          "imports 'package:hidden/hidden.dart', but package 'hidden' is not a direct dependency",
        ),
      );
      expect(output, contains("Add the target that provides package 'hidden'"));
    });

    // Fails when `aspects = [dart_import_check_aspect]` is removed from the
    // `deps` attribute in `dev/import_check_export/defs.bzl`: the executable's
    // own `main` is clean, so only the aspect reports the dependency's source.
    test('a dependency importing a package its deps lack fails the check', () {
      final ProcessResult result = build(['//import_check_export:bad_dep']);
      final output = '${result.stdout}${result.stderr}';
      expect(result.exitCode, isNot(0), reason: output);
      expect(
        output,
        matches(
          RegExp(
            r"dep_bad[^\n]*imports 'package:hidden/hidden\.dart', but package 'hidden' is not a direct dependency",
          ),
        ),
      );
      expect(output, contains("Add the target that provides package 'hidden'"));
    });
  });
}

void _registerExeMirrorsTest(ProcessResult Function(List<String>) build) {
  group('exe compile path', () {
    // Fails when the rule's `exe` path links per-library modules: they compile
    // against the JIT platform, where `dart:mirrors` exists, so the build
    // succeeds. The default whole-program AOT path refuses the import.
    test('dart:mirrors is refused by the front end with a line', () {
      final ProcessResult result = build(['//exe_mirrors:mirrors_exe']);
      final output = '${result.stdout}${result.stderr}';
      expect(result.exitCode, isNot(0), reason: output);
      expect(
        output,
        matches(
          RegExp(
            r"mirrors_main\.dart:\d+:\d+: Error: Dart library 'dart:mirrors' "
            'is not available on this platform',
          ),
        ),
      );
    });
  });
}

/// Runs `bazel build` for [targets] in the nested `dev` module.
///
/// `--lockfile_mode=error` builds the exported API against the committed
/// `dev/MODULE.bazel.lock`, as a consumer builds it; a stale lock fails here
/// and the error names `MODULE.bazel.lock`. After a module extension change,
/// refresh it: `cd dev && export USE_BAZEL_VERSION="$(cat ../.bazelversion)"
/// && bazel build --nobuild --lockfile_mode=update //...`.
ProcessResult _build(_BazelConfig config, List<String> targets) =>
    _spawnBazel(config, [
      'build',
      '--lockfile_mode=error',
      '--experimental_convenience_symlinks=ignore',
      ...targets,
    ]);

ProcessResult _spawnBazel(_BazelConfig config, List<String> commandArgs) =>
    Process.runSync(
      config.executable,
      [...config.startupArgs, ...commandArgs],
      workingDirectory: config.workingDirectory,
      environment: config.environment,
      includeParentEnvironment: false,
      runInShell: config.runInShell,
    );

void _cleanup(
  _BazelConfig config,
  Directory scratch, {
  required bool serverStarted,
}) {
  if (serverStarted) {
    try {
      final ProcessResult expunge = _spawnBazel(config, ['clean', '--expunge']);
      if (expunge.exitCode != 0) {
        _spawnBazel(config, ['shutdown']);
      }
    } on ProcessException catch (e) {
      stderr.writeln('nested bazel shutdown failed: ${e.message}');
    }
  }
  try {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('scratch cleanup failed: ${e.message}');
  }
}

_HostFs _realHostFs({required bool isWindows}) => (
  fileExists: (path) => File(path).existsSync(),
  executableExists: (path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    return isWindows || (file.statSync().mode & 0x49) != 0;
  },
  readText: (path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  },
);

/// Builds the nested Bazel launch configuration for [root] and [scratchPath].
_BazelConfig _prepareBazel({
  required String root,
  required String scratchPath,
  required Map<String, String> hostEnv,
  required _HostFs fs,
  required bool isWindows,
}) {
  final p.Context ctx = isWindows ? p.windows : p.posix;
  final String normRoot = _nativePath(root, isWindows: isWindows);
  final String normScratch = _nativePath(scratchPath, isWindows: isWindows);
  final String outputBase = ctx.join(normScratch, 'ob');
  final String tmpDir = ctx.join(normScratch, 'tmp');
  final ({String? home, String? bazelrc}) homeRc = _resolveHomeAndRc(
    hostEnv,
    fs: fs,
    isWindows: isWindows,
  );
  final ({String executable, bool runInShell, bool usedBazelReal}) client =
      _resolveBazel(hostEnv, fs: fs, isWindows: isWindows);
  final String? versionText = fs.readText(ctx.join(normRoot, '.bazelversion'));
  final Map<String, String> env = _childEnvironment(
    hostEnv,
    home: homeRc.home,
    tmpDir: tmpDir,
    pinnedVersion: client.usedBazelReal ? null : versionText?.trim(),
    isWindows: isWindows,
  );
  return (
    executable: client.executable,
    runInShell: client.runInShell,
    workingDirectory: ctx.join(normRoot, 'dev'),
    startupArgs: <String>[
      '--output_base=$outputBase',
      '--max_idle_secs=30',
      if (homeRc.bazelrc != null) ...[
        '--nohome_rc',
        '--bazelrc=${homeRc.bazelrc}',
      ],
    ],
    environment: env,
  );
}

Map<String, String> _childEnvironment(
  Map<String, String> hostEnv, {
  required String? home,
  required String tmpDir,
  required String? pinnedVersion,
  required bool isWindows,
}) {
  final env = <String, String>{};
  for (final MapEntry<String, String> entry in hostEnv.entries) {
    if (_outerTestVars.contains(entry.key.toUpperCase())) continue;
    _putEnv(env, entry.key, entry.value, isWindows: isWindows);
  }
  if (home != null && home.isNotEmpty) {
    _putEnv(env, 'HOME', home, isWindows: isWindows);
    if (isWindows) _putEnv(env, 'USERPROFILE', home, isWindows: true);
  }
  _putEnv(env, 'TMP', tmpDir, isWindows: isWindows);
  _putEnv(env, 'TEMP', tmpDir, isWindows: isWindows);
  if (!isWindows) env['TMPDIR'] = tmpDir;
  if (pinnedVersion != null &&
      pinnedVersion.isNotEmpty &&
      _envValue(env, 'USE_BAZEL_VERSION', isWindows: isWindows) == null) {
    _putEnv(env, 'USE_BAZEL_VERSION', pinnedVersion, isWindows: isWindows);
  }
  return env;
}

void _putEnv(
  Map<String, String> env,
  String key,
  String value, {
  required bool isWindows,
}) {
  if (isWindows) {
    final String upper = key.toUpperCase();
    env.removeWhere((existing, _) => existing.toUpperCase() == upper);
  }
  env[key] = value;
}

/// Resolves the outer Bazel binary (`BAZEL_REAL`, `PATH`, or shell fallback).
({String executable, bool runInShell, bool usedBazelReal}) _resolveBazel(
  Map<String, String> env, {
  required _HostFs fs,
  required bool isWindows,
}) {
  final String? real = _envValue(env, 'BAZEL_REAL', isWindows: isWindows);
  if (real != null && real.isNotEmpty) {
    final String path = _nativePath(real, isWindows: isWindows);
    if (fs.executableExists(path)) {
      return (
        executable: path,
        runInShell: isWindows && !_isDirectWindowsExe(path),
        usedBazelReal: true,
      );
    }
  }
  final String? fromPath = _searchPathForBazel(
    env,
    fs: fs,
    isWindows: isWindows,
  );
  if (fromPath != null) {
    return (
      executable: fromPath,
      runInShell: isWindows && !_isDirectWindowsExe(fromPath),
      usedBazelReal: false,
    );
  }
  return (executable: 'bazel', runInShell: isWindows, usedBazelReal: false);
}

bool _isDirectWindowsExe(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.exe') || lower.endsWith('.com');
}

String? _searchPathForBazel(
  Map<String, String> env, {
  required _HostFs fs,
  required bool isWindows,
}) {
  final String? rawPath = _envValue(env, 'PATH', isWindows: isWindows);
  if (rawPath == null || rawPath.isEmpty) return null;
  final p.Context ctx = isWindows ? p.windows : p.posix;
  final List<String> names = isWindows ? _windowsBazelNames(env) : ['bazel'];
  for (final String rawEntry in rawPath.split(isWindows ? ';' : ':')) {
    final String trimmed = _unquote(rawEntry);
    if (trimmed.isEmpty) continue;
    final String dir = _nativePath(trimmed, isWindows: isWindows);
    for (final name in names) {
      final String candidate = ctx.join(dir, name);
      if (fs.executableExists(candidate)) return candidate;
    }
  }
  return null;
}

List<String> _windowsBazelNames(Map<String, String> env) {
  final String? rawExt = _envValue(env, 'PATHEXT', isWindows: true);
  if (rawExt == null || rawExt.isEmpty) {
    return const ['bazel.exe', 'bazel.com', 'bazel.cmd', 'bazel.bat', 'bazel'];
  }
  return <String>[
    for (final String part in rawExt.split(';'))
      if (part.trim().isNotEmpty) 'bazel${_dotPrefixed(part.trim())}',
    'bazel',
  ];
}

String _dotPrefixed(String ext) {
  final String lower = ext.toLowerCase();
  return lower.startsWith('.') ? lower : '.$lower';
}

String _unquote(String value) {
  final String s = value.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1);
  }
  return s;
}

/// Selects a short parent directory for the nested Bazel's output base.
String _scratchParent(
  Map<String, String> env, {
  required bool isWindows,
  required String systemTempPath,
  required bool Function(String path) dirExists,
}) {
  final candidates = <String?>[
    if (isWindows) ...[
      _envValue(env, 'RUNNER_TEMP', isWindows: true),
      _localAppDataTemp(env),
      systemTempPath,
    ] else ...[
      env['TEST_TMPDIR'],
      systemTempPath,
    ],
  ];
  for (final raw in candidates) {
    if (raw == null || raw.isEmpty) continue;
    final String norm = _nativePath(raw, isWindows: isWindows);
    if (dirExists(norm)) return norm;
  }
  return _nativePath(systemTempPath, isWindows: isWindows);
}

String? _localAppDataTemp(Map<String, String> env) {
  final String? local = _envValue(env, 'LOCALAPPDATA', isWindows: true);
  if (local == null || local.isEmpty) return null;
  return p.windows.join(_nativePath(local, isWindows: true), 'Temp');
}

/// Finds the outer user's home directory and its `.bazelrc` when present.
({String? home, String? bazelrc}) _resolveHomeAndRc(
  Map<String, String> env, {
  required _HostFs fs,
  required bool isWindows,
}) {
  final p.Context ctx = isWindows ? p.windows : p.posix;
  final List<String> candidates = _homeCandidates(env, isWindows: isWindows);
  for (final dir in candidates) {
    final String rc = ctx.join(dir, '.bazelrc');
    if (fs.fileExists(rc)) return (home: dir, bazelrc: rc);
  }
  return (home: candidates.firstOrNull, bazelrc: null);
}

List<String> _homeCandidates(
  Map<String, String> env, {
  required bool isWindows,
}) {
  final dirs = <String>[];
  void add(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final String norm = _nativePath(raw, isWindows: isWindows);
    if (!dirs.contains(norm)) dirs.add(norm);
  }

  if (isWindows) {
    add(_envValue(env, 'USERPROFILE', isWindows: true));
    final String? drive = _envValue(env, 'HOMEDRIVE', isWindows: true);
    final String? homePath = _envValue(env, 'HOMEPATH', isWindows: true);
    if (drive != null &&
        homePath != null &&
        drive.isNotEmpty &&
        homePath.isNotEmpty) {
      add('$drive$homePath');
    }
  }
  add(_envValue(env, 'HOME', isWindows: isWindows));
  final String? tmp =
      _envValue(env, 'TEST_TMPDIR', isWindows: isWindows) ??
      _envValue(env, 'TMP', isWindows: isWindows);
  if (tmp != null) add(_prefixBeforeBazelCache(tmp, isWindows: isWindows));
  return dirs;
}

String? _prefixBeforeBazelCache(String raw, {required bool isWindows}) {
  final String norm = _nativePath(raw, isWindows: isWindows);
  final String slash = norm.replaceAll(r'\', '/');
  for (final marker in ['/.cache/bazel/', '/_bazel_']) {
    final int cut = slash.indexOf(marker);
    if (cut > 0) {
      final String prefix = norm.substring(0, cut);
      if (!isWindows || prefix.length > 2) return prefix;
    }
  }
  return null;
}

String _nativePath(String raw, {required bool isWindows}) {
  if (!isWindows) return p.posix.normalize(raw);
  final Match? msys = _msysDrive.firstMatch(raw);
  final mapped = msys == null
      ? raw
      : '${msys.group(1)!.toUpperCase()}:${msys.group(2) ?? r'\'}';
  return p.windows.normalize(mapped);
}

String? _envValue(
  Map<String, String> env,
  String key, {
  required bool isWindows,
}) {
  final String? direct = env[key];
  if (direct != null) return direct;
  if (!isWindows) return null;
  final String upper = key.toUpperCase();
  for (final MapEntry<String, String> entry in env.entries) {
    if (entry.key.toUpperCase() == upper) return entry.value;
  }
  return null;
}

/// The source-tree workspace root, from the runfiles path of this test's source.
String _workspaceRoot(String rlocationPath) {
  final String located = Runfiles.create().rlocation(rlocationPath);
  final String real = File(located).resolveSymbolicLinksSync();
  return File(real).parent.parent.parent.parent.path;
}

void _registerLauncherConfigTests() {
  group('Windows nested Bazel configuration', () {
    test(
      'uses BAZEL_REAL directly and loads USERPROFILE .bazelrc',
      _expectBazelRealAndUserprofileRc,
    );

    test(
      'resolves bazel wrapper on Path and falls back to shell',
      _expectPathWrapperAndShellFallback,
    );

    test('prefers short RUNNER_TEMP over deep Bazel TEST_TMPDIR', () {
      final String parent = _scratchParent(
        const <String, String>{
          'RUNNER_TEMP': 'D:/a/_temp',
          'TEST_TMPDIR':
              'D:/a/_temp/bazel-servers/_/execroot/_main/_tmp/very_long_hash',
        },
        isWindows: true,
        systemTempPath: r'D:\a\_temp\bazel-servers\_\execroot\_main\_tmp\long',
        dirExists: (path) => path == r'D:\a\_temp',
      );
      expect(parent, r'D:\a\_temp');
    });
  });
}

void _expectBazelRealAndUserprofileRc() {
  const files = <String>{
    r'C:\Users\runneradmin\AppData\Local\bazelisk\bin\bazel.exe',
    r'C:\Users\runneradmin\.bazelrc',
  };
  final _BazelConfig cfg = _prepareBazel(
    root: 'D:/a/ai_rules_dart/ai_rules_dart',
    scratchPath: 'D:/a/_temp/rd_ice_1',
    hostEnv: <String, String>{
      'BAZEL_REAL': 'C:/Users/runneradmin/AppData/Local/bazelisk/bin/bazel.exe',
      'HOME': '/c/Users/runneradmin',
      'USERPROFILE': r'C:\Users\runneradmin',
      'Path': r'C:\Windows\System32',
      'TEST_TMPDIR': 'D:/a/_temp/bazel-servers/_/execroot/_main/_tmp/abc',
    },
    fs: (
      fileExists: files.contains,
      executableExists: files.contains,
      readText: (_) => '9.3.0\n',
    ),
    isWindows: true,
  );
  expect(
    cfg.executable,
    r'C:\Users\runneradmin\AppData\Local\bazelisk\bin\bazel.exe',
  );
  expect(cfg.runInShell, isFalse);
  expect(cfg.workingDirectory, r'D:\a\ai_rules_dart\ai_rules_dart\dev');
  expect(
    cfg.startupArgs,
    equals([
      r'--output_base=D:\a\_temp\rd_ice_1\ob',
      '--max_idle_secs=30',
      '--nohome_rc',
      r'--bazelrc=C:\Users\runneradmin\.bazelrc',
    ]),
  );
  expect(cfg.environment['HOME'], r'C:\Users\runneradmin');
  expect(cfg.environment['USERPROFILE'], r'C:\Users\runneradmin');
  expect(cfg.environment['TEMP'], r'D:\a\_temp\rd_ice_1\tmp');
  expect(cfg.environment.containsKey('TEST_TMPDIR'), isFalse);
  expect(cfg.environment.containsKey('USE_BAZEL_VERSION'), isFalse);
}

void _expectPathWrapperAndShellFallback() {
  const cmdFiles = <String>{r'C:\ProgramData\chocolatey\bin\bazel.cmd'};
  final _BazelConfig cmdCfg = _prepareBazel(
    root: r'D:\ws',
    scratchPath: r'D:\a\_temp\s',
    hostEnv: <String, String>{
      'Path': r'"C:\ProgramData\chocolatey\bin";C:\Windows\System32',
      'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      'HOME': '/c/Users/dev',
    },
    fs: (
      fileExists: cmdFiles.contains,
      executableExists: cmdFiles.contains,
      readText: (_) => '9.3.0\n',
    ),
    isWindows: true,
  );
  expect(cmdCfg.executable, r'C:\ProgramData\chocolatey\bin\bazel.cmd');
  expect(cmdCfg.runInShell, isTrue);
  expect(cmdCfg.environment['HOME'], r'C:\Users\dev');
  expect(cmdCfg.environment['USERPROFILE'], r'C:\Users\dev');
  expect(cmdCfg.environment['USE_BAZEL_VERSION'], '9.3.0');

  final _BazelConfig shellFallback = _prepareBazel(
    root: r'D:\ws',
    scratchPath: r'D:\a\_temp\s',
    hostEnv: const <String, String>{'Path': r'C:\Windows\System32'},
    fs: (
      fileExists: (_) => false,
      executableExists: (_) => false,
      readText: (_) => null,
    ),
    isWindows: true,
  );
  expect(shellFallback.executable, 'bazel');
  expect(shellFallback.runInShell, isTrue);
}
