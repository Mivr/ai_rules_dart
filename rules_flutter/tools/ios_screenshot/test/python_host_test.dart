/// Tests for the host-Python launch guard ([python_host]).
///
/// Runs the real host `python3` from a directory holding a planted module and
/// shows the planted module is not imported, while a module on the user site
/// path still is. A hostile `PYTHONHOME` tree (a copy of the real standard
/// library whose `argparse` carries a planted marker) is ignored the same
/// way, both ambient (a child `dart` process drives the launchers with
/// `PYTHONHOME` in its own environment, which this process cannot take on)
/// and caller-passed (through the launchers' `environment`). Skipped, with a
/// printed reason, only when the host has no `python3`.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../lib/python_host.dart';

typedef _Planted = ({Directory plantedDir, String userBase});
typedef _Stdin = ({
  List<String> arguments,
  Map<String, String> environment,
  String program,
});

/// Probe run through both launchers: reports whether the standard library
/// came from a hostile `PYTHONHOME` tree, whether a module from the
/// launcher's working directory imports, and whether a module from the user
/// site imports.
///
/// The report goes to the file named by `sys.argv[1]` rather than stdout,
/// because the launchers forward the child's stdout to this process's.
const String _probeProgram = r'''
import sys

try:
    import argparse
    home = getattr(
        argparse, 'IOS_SCREENSHOT_HOME_MARKER', None) == 'home-shim-xyz'
except ImportError:
    home = False

try:
    import ios_screenshot_planted_xyz
    planted = True
except ImportError:
    planted = False

try:
    import ios_screenshot_site_xyz
    site_ok = ios_screenshot_site_xyz.MARKER == 'site-shim-xyz'
except ImportError:
    site_ok = False

with open(sys.argv[1], 'w') as handle:
    handle.write('home=%s planted=%s site=%s' % (home, planted, site_ok))
''';

/// Driver run by a child `dart` process to drive one launcher from a hostile
/// ambient environment. `LIB_URI` is replaced with the `file:` URI of the
/// real `python_host.dart` before writing; arguments are the carrier
/// (`stdin` or `argv`), the interpreter, the probe file, the report file,
/// and optionally a `PYTHONUSERBASE` passed through as caller overrides.
const String _driverProgram = r'''
import 'dart:io';

import 'LIB_URI';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final python = args[1];
  final program = File(args[2]).readAsStringSync();
  final out = args[3];
  final Map<String, String>? environment =
      args.length > 4 ? {'PYTHONUSERBASE': args[4]} : null;
  final exitCode = mode == 'argv'
      ? await runPythonProgramInteractive(
          python, program, [out], environment: environment)
      : await runPythonProgram(
          python, program, [out], environment: environment);
  exit(exitCode);
}
''';

/// The report a guarded launch of [_probeProgram] writes.
const String _cleanReport = 'home=False planted=False site=True';

void main() {
  _dartBinaryTests();
  group('guarded host-Python launch', () {
    late Directory workDir;
    late String? python;

    setUp(() {
      workDir = Directory.systemTemp.createTempSync('python_host_test_');
      python = findHostPython();
    });

    tearDown(() {
      workDir.deleteSync(recursive: true);
    });

    test(
      'stdin program ignores the working directory, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final out = '${workDir.path}/report.txt';
        final int exitCode = await runPythonProgram(
          interpreter,
          _probeProgram,
          [out],
          workingDirectory: planted.plantedDir.path,
          environment: {'PYTHONUSERBASE': planted.userBase},
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals(_cleanReport));
      },
    );

    test(
      '`-c` program ignores the working directory, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final out = '${workDir.path}/report_c.txt';
        final int exitCode = await runPythonProgramInteractive(
          interpreter,
          _probeProgram,
          [out],
          workingDirectory: planted.plantedDir.path,
          environment: {'PYTHONUSERBASE': planted.userBase},
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals(_cleanReport));
      },
    );

    test(
      'stdin program ignores an ambient PYTHONHOME, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final Directory home = await _fakePythonHome(interpreter, workDir);
        final out = '${workDir.path}/report_home.txt';
        final ({int exitCode, String logs, String report}) run =
            await _runWithAmbientHome(
              mode: 'stdin',
              python: interpreter,
              out: out,
              userBase: planted.userBase,
              home: home,
            );
        expect(run.exitCode, equals(0), reason: run.logs);
        expect(run.report, equals(_cleanReport));
      },
    );

    test(
      '`-c` program ignores an ambient PYTHONHOME, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final Directory home = await _fakePythonHome(interpreter, workDir);
        final out = '${workDir.path}/report_home_c.txt';
        final ({int exitCode, String logs, String report}) run =
            await _runWithAmbientHome(
              mode: 'argv',
              python: interpreter,
              out: out,
              userBase: planted.userBase,
              home: home,
            );
        expect(run.exitCode, equals(0), reason: run.logs);
        expect(run.report, equals(_cleanReport));
      },
    );

    test(
      'stdin program ignores a caller-passed PYTHONHOME, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final Directory home = await _fakePythonHome(interpreter, workDir);
        final out = '${workDir.path}/report_env_home.txt';
        final int exitCode = await runPythonProgram(
          interpreter,
          _probeProgram,
          [out],
          environment: {
            'PYTHONHOME': home.path,
            'PYTHONUSERBASE': planted.userBase,
          },
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals(_cleanReport));
      },
    );

    test(
      '`-c` program ignores a caller-passed PYTHONHOME, keeps user site',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final _Planted planted = await _plantModules(interpreter, workDir);
        final Directory home = await _fakePythonHome(interpreter, workDir);
        final out = '${workDir.path}/report_env_home_c.txt';
        final int exitCode = await runPythonProgramInteractive(
          interpreter,
          _probeProgram,
          [out],
          environment: {
            'PYTHONHOME': home.path,
            'PYTHONUSERBASE': planted.userBase,
          },
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals(_cleanReport));
      },
    );

    test(
      'relative output path still resolves under the working directory',
      () async {
        final String? interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final int exitCode = await runPythonProgram(
          interpreter,
          'with open(\'rel_report_xyz.txt\', \'w\') as handle:\n'
          '    handle.write(\'here\')\n',
          const [],
          workingDirectory: workDir.path,
        );
        expect(exitCode, equals(0));
        expect(
          File('${workDir.path}/rel_report_xyz.txt').readAsStringSync(),
          equals('here'),
        );
      },
    );

    test('guard helpers strip what the tool did not choose', () {
      final Map<String, String> env = guardedPythonEnvironment({
        'PYTHONPATH': '/attacker',
        'PYTHONHOME': '/attacker/home',
        'PYTHONPLATLIBDIR': '/attacker/plat',
        'PYTHONSTARTUP': '/attacker/startup.py',
        'PYTHONUSERBASE': '/user/base',
        'EXTRA': 'kept',
      });
      expect(env['PYTHONPATH'], isNull);
      expect(env['PYTHONHOME'], isNull);
      expect(env['PYTHONPLATLIBDIR'], isNull);
      expect(env['PYTHONSTARTUP'], isNull);
      expect(env['PYTHONSAFEPATH'], equals('1'));
      expect(env['PYTHONUSERBASE'], equals('/user/base'));
      expect(env['EXTRA'], equals('kept'));
      expect(env['PATH'], equals(Platform.environment['PATH']));
      expect(
        guardPythonProgram('import planted'),
        contains('_flutter_bazel_guard_sys_path'),
      );
    });

    test('guard forwards a user-disabled user site', () {
      final Map<String, String> env = guardedPythonEnvironment({
        'PYTHONNOUSERSITE': '1',
        'PYTHONUSERBASE': '/user/base',
      });
      expect(env['PYTHONNOUSERSITE'], equals('1'));
      expect(env['PYTHONUSERBASE'], equals('/user/base'));
    });

    test('one launch helper serves both carriers', () {
      final _Stdin stdin = guardedPythonLaunch(
        'print(1)',
        ['a'],
        interactive: false,
        environment: {'PYTHONHOME': '/attacker/home'},
      );
      expect(stdin.arguments, equals(['-', 'a']));
      expect(stdin.environment['PYTHONHOME'], isNull);
      expect(stdin.environment['PYTHONSAFEPATH'], equals('1'));
      expect(stdin.program, contains('_flutter_bazel_guard_sys_path'));
      final _Stdin argv = guardedPythonLaunch('print(1)', [
        'a',
      ], interactive: true);
      expect(argv.arguments.first, equals('-c'));
      expect(argv.arguments.last, equals('a'));
      expect(argv.arguments[1], equals(argv.program));
    });
  });
}

/// The interpreter to run, or marks the calling test skipped naming why.
String? _skipWhenNoPython(String? python) {
  if (python == null) {
    markTestSkipped(
      'no python3 on PATH, so the launcher tests cannot run; '
      'install Python 3 to run them',
    );
  }
  return python;
}

/// A working directory holding a planted module, and a user base whose site
/// packages hold a shim module the launchers must still import.
Future<_Planted> _plantModules(
  String python,
  Directory workDir,
) async {
  final plantedDir = Directory('${workDir.path}/cwd')..createSync();
  File('${plantedDir.path}/ios_screenshot_planted_xyz.py')
      .writeAsStringSync("MARKER = 'planted-xyz'\n");
  final userBase = '${workDir.path}/userbase';
  final String usersite = await _pythonPrint(
    python,
    'import site; print(site.getusersitepackages())',
    'the user site',
    {'PYTHONUSERBASE': userBase},
  );
  Directory(usersite).createSync(recursive: true);
  File('$usersite/ios_screenshot_site_xyz.py')
      .writeAsStringSync("MARKER = 'site-shim-xyz'\n");
  return (plantedDir: plantedDir, userBase: userBase);
}

/// A hostile `PYTHONHOME` tree: a copy of the real standard library whose
/// `argparse` carries a planted marker, so a child that resolves its
/// standard library from the ambient `PYTHONHOME` imports attacker code.
Future<Directory> _fakePythonHome(
  String python,
  Directory workDir,
) async {
  final stdlib = Directory(
    await _pythonPrint(
      python,
      'import sysconfig; print(sysconfig.get_path("stdlib"))',
      'the standard library path',
      null,
    ),
  );
  final home = Directory('${workDir.path}/fakehome')..createSync();
  final String base = stdlib.path.split(Platform.pathSeparator).last;
  final target = Directory(
    Platform.isWindows ? '${home.path}/Lib' : '${home.path}/lib/$base',
  )..createSync(recursive: true);
  _copyTree(stdlib, target);
  File('${target.path}/argparse.py').writeAsStringSync(
    "\nIOS_SCREENSHOT_HOME_MARKER = 'home-shim-xyz'\n",
    mode: FileMode.append,
  );
  return home;
}

/// Copies [from] to [to], leaving out bytecode caches so the copy never
/// serves stale bytecode for a source file the test plants afterwards.
void _copyTree(Directory from, Directory to) {
  for (final FileSystemEntity entity in from.listSync(
    recursive: false,
    followLinks: false,
  )) {
    final String name = entity.uri.pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
    );
    if (entity is Directory) {
      if (name == '__pycache__') continue;
      final child = Directory('${to.path}/$name')..createSync();
      _copyTree(entity, child);
    } else if (entity is Link) {
      Link('${to.path}/$name').createSync(entity.targetSync());
    } else if (entity is File) {
      entity.copySync('${to.path}/$name');
    }
  }
}

/// Runs one launcher in a child `dart` process whose own environment carries
/// `PYTHONHOME=[home.path]`: the ambient case this process cannot take on
/// itself. Returns the launcher's exit code, the probe report (empty when
/// the probe never ran), and the child's output for failure diagnostics.
Future<({int exitCode, String report, String logs})> _runWithAmbientHome({
  required String mode,
  required String python,
  required String out,
  required String userBase,
  required Directory home,
}) async {
  final Directory dir = File(out).parent;
  File('${dir.path}/driver_xyz.dart').writeAsStringSync(
    _driverProgram.replaceFirst(
      'LIB_URI',
      Uri.file(_libSource()).toString(),
    ),
  );
  File('${dir.path}/probe_xyz.py').writeAsStringSync(_probeProgram);
  final ProcessResult result = await Process.run(
    _dartBinary(),
    [
      '${dir.path}/driver_xyz.dart',
      mode,
      python,
      '${dir.path}/probe_xyz.py',
      out,
      userBase,
    ],
    environment: {'PYTHONHOME': home.path},
  );
  final logs = '${result.stdout}${result.stderr}';
  final String report = File(out).existsSync()
      ? File(out).readAsStringSync()
      : '';
  return (exitCode: result.exitCode, report: report, logs: logs);
}

/// The last line [python] prints for [snippet], run with [environment].
Future<String> _pythonPrint(
  String python,
  String snippet,
  String what,
  Map<String, String>? environment,
) async {
  final ProcessResult result = await Process.run(
    python,
    ['-c', snippet],
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError('could not read $what: ${result.stderr}');
  }
  return (result.stdout as String).trim().split('\n').last;
}

/// The SDK `dart` that runs test kernels, for driving a nested launcher.
String _dartBinary([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? key = env['IOS_SCREENSHOT_DART_RLOCATION'];
  if (key == null || key.isEmpty) {
    throw StateError(
      'IOS_SCREENSHOT_DART_RLOCATION is not set; '
      'the test needs @rules_dart//dart in `data`',
    );
  }
  return File(Runfiles.create().rlocation(key)).absolute.path;
}

/// The `python_host.dart` source the nested driver imports.
String _libSource() {
  final String? key =
      Platform.environment['IOS_SCREENSHOT_PYTHON_HOST_RLOCATION'];
  if (key == null || key.isEmpty) {
    throw StateError(
      'IOS_SCREENSHOT_PYTHON_HOST_RLOCATION is not set; '
      'the test needs lib/python_host.dart in `data`',
    );
  }
  return File(Runfiles.create().rlocation(key)).absolute.path;
}

/// Registers tests verifying that [_dartBinary] resolves solely from runfiles.
void _dartBinaryTests() {
  group('_dartBinary', () {
    test('resolves Dart SDK executable from runfiles without PATH', () async {
      final String? rlocation =
          Platform.environment['IOS_SCREENSHOT_DART_RLOCATION'];
      expect(rlocation, isNotNull);
      expect(rlocation, isNotEmpty);
      final String dartPath = _dartBinary();
      expect(File(dartPath).existsSync(), isTrue);
      final ProcessResult result = await Process.run(
        dartPath,
        ['--version'],
        environment: {'PATH': ''},
      );
      expect(result.exitCode, equals(0));
      final versionOutput = '${result.stdout}${result.stderr}';
      expect(versionOutput, contains('Dart SDK version'));
    });

    test('throws StateError when rlocation variable is absent', () {
      final Directory tempDir = _createDummyDartDir();
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final String legacyDartKey = ['RULES', 'DART', 'DART'].join('_');
      final dummyDart = Platform.isWindows
          ? '${tempDir.path}/dart.exe'
          : '${tempDir.path}/dart';
      final Map<String, String> env = {
        legacyDartKey: dummyDart,
        'PATH': tempDir.path,
      };
      expect(
        () => _dartBinary(env),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('IOS_SCREENSHOT_DART_RLOCATION'),
              contains('@rules_dart//dart'),
            ),
          ),
        ),
      );
    });

    test('throws StateError when rlocation variable is empty', () {
      final Directory tempDir = _createDummyDartDir();
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final String legacyDartKey = ['RULES', 'DART', 'DART'].join('_');
      final dummyDart = Platform.isWindows
          ? '${tempDir.path}/dart.exe'
          : '${tempDir.path}/dart';
      final Map<String, String> env = {
        'IOS_SCREENSHOT_DART_RLOCATION': '',
        legacyDartKey: dummyDart,
        'PATH': tempDir.path,
      };
      expect(
        () => _dartBinary(env),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('IOS_SCREENSHOT_DART_RLOCATION'),
              contains('@rules_dart//dart'),
            ),
          ),
        ),
      );
    });
  });
}

/// Creates a temporary directory containing dummy `dart` executables.
Directory _createDummyDartDir() {
  final Directory tempDir = Directory.systemTemp.createTempSync('dart_dummy_');
  File('${tempDir.path}/dart').writeAsStringSync('');
  File('${tempDir.path}/dart.exe').writeAsStringSync('');
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', '${tempDir.path}/dart']);
  }
  return tempDir;
}
