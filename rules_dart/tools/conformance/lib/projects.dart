/// What is built for each corpus project, on each side.
///
/// The stock side runs what a developer runs; the rules side builds a fixed
/// target of the project's overlay (`overlays/<project>/`): `//:web`,
/// `//:apk` (with `-c dbg`), `//:linux`, `//:calc`, every test under `//...`,
/// and the `dart_analyze` aspect over `//...` with `//:analysis_config`.
library;

import 'package:conformance/layout.dart';

/// One kind of output for one project.
class KindSpec {
  const KindSpec({
    required this.stock,
    this.stockOutput,
    this.target,
    this.bazelFlags = const [],
    this.inputs = const [],
  });

  /// The stock command, run in the project copy after `pub get`.
  final List<String> stock;

  /// Where the stock command leaves its output, relative to the copy.
  final String? stockOutput;

  /// The rules' target (none for tests and analysis, which cover `//...`).
  final String? target;

  /// Extra Bazel flags for this kind.
  final List<String> bazelFlags;

  /// `exe`: the argument lists the program is run with.
  final List<List<String>> inputs;
}

/// One corpus project.
class ProjectSpec {
  const ProjectSpec({
    required this.name,
    required this.flutter,
    required this.kinds,
    this.prepare = const {},
  });

  final String name;

  /// A Flutter app (`flutter` commands, the Flutter module) or a Dart package.
  final bool flutter;

  /// Files copied inside the project copy before anything runs: to <- from.
  final Map<String, String> prepare;

  final Map<Kind, KindSpec> kinds;

  /// Whether the rules side needs the Android toolchain.
  bool get android => kinds.containsKey(Kind.apk);

  List<String> get tool => flutter ? ['flutter'] : ['dart'];
}

const _flutterTests = KindSpec(
  stock: ['flutter', 'test', '--reporter', 'json'],
);

const _linux = KindSpec(
  stock: ['flutter', 'build', 'linux', '--debug'],
  stockOutput: 'build/linux/x64/debug/bundle',
  target: '//:linux',
);

/// The defines `flavors_defines` is built with on both sides (as in the stock
/// baselines of T07).
const flavorDefines = [
  '--dart-define=FLAVOR=prod',
  '--dart-define=API_URL=https://api.example.invalid',
  '--dart-define=RETRIES=5',
];

/// The corpus, by name.
const Map<String, ProjectSpec> projects = {
  'dart_pkg': ProjectSpec(
    name: 'dart_pkg',
    flutter: false,
    prepare: {'pubspec.lock': 'pubspec.lock.pinned'},
    kinds: {
      Kind.tests: KindSpec(stock: ['dart', 'test', '--reporter', 'json']),
      Kind.analysis: KindSpec(stock: ['dart', 'analyze']),
      Kind.exe: KindSpec(
        stock: [
          'dart',
          'compile',
          'exe',
          'example/calc.dart',
          '-o',
          'calc.exe',
        ],
        stockOutput: 'calc.exe',
        target: '//:calc',
        inputs: [
          ['1 + 2 * 3'],
          ['2 ^ 10 - 24'],
          ['(1 + 2) * -3.5'],
          ['1e3 / 8'],
          ['1 +'],
          [''],
        ],
      ),
    },
  ),
  'counter': ProjectSpec(
    name: 'counter',
    flutter: true,
    kinds: {
      Kind.tests: _flutterTests,
      Kind.web: KindSpec(
        stock: ['flutter', 'build', 'web'],
        stockOutput: 'build/web',
        target: '//:web',
      ),
      Kind.apk: KindSpec(
        stock: ['flutter', 'build', 'apk', '--debug'],
        stockOutput: 'build/app/outputs/flutter-apk/app-debug.apk',
        target: '//:apk',
        bazelFlags: ['-c', 'dbg'],
      ),
      Kind.linux: _linux,
    },
  ),
  'flavors_defines': ProjectSpec(
    name: 'flavors_defines',
    flutter: true,
    kinds: {
      Kind.tests: _flutterTests,
      Kind.web: KindSpec(
        stock: ['flutter', 'build', 'web', ...flavorDefines],
        stockOutput: 'build/web',
        target: '//:web',
      ),
      Kind.apk: KindSpec(
        stock: [
          'flutter',
          'build',
          'apk',
          '--debug',
          '--flavor',
          'dev',
          ...flavorDefines,
        ],
        stockOutput: 'build/app/outputs/flutter-apk/app-dev-debug.apk',
        target: '//:apk',
        bazelFlags: ['-c', 'dbg'],
      ),
      Kind.linux: _linux,
    },
  ),
  'large': ProjectSpec(
    name: 'large',
    flutter: true,
    kinds: {
      Kind.tests: _flutterTests,
      Kind.web: KindSpec(
        stock: ['flutter', 'build', 'web'],
        stockOutput: 'build/web',
        target: '//:web',
      ),
      Kind.linux: _linux,
    },
  ),
};
