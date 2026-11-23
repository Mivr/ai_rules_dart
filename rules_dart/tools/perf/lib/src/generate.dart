/// Generated workspaces: the layered library graph (a Bazel workspace and its
/// stock twin, a pub workspace of the same libraries), the per-source-file
/// action probe, and the code generation package.
library;

import 'dart:io';

/// The shape of a layered graph.
enum Shape {
  /// Many layers of 20 libraries.
  deep,

  /// Four layers.
  wide,
}

/// Library graph settings.
final class GraphSpec {
  /// A graph of [libraries] libraries.
  const GraphSpec({
    required this.libraries,
    this.shape = Shape.deep,
    this.flutter = false,
    this.methods = 0,
    this.packageTest = false,
  });

  /// Total libraries (rounded down to a whole number of layers).
  final int libraries;

  /// Deep or wide.
  final Shape shape;

  /// Flutter libraries (`flutter_library`, a widget each, an app on top)
  /// instead of Dart ones.
  final bool flutter;

  /// Methods of the model class in each library, six lines each: the body
  /// size knob (0 gives the bare graph of `gen_scale`).
  final int methods;

  /// Tests use `package:test` (the Bazel side then needs a pub hub).
  final bool packageTest;

  /// Libraries per layer.
  int get width => shape == Shape.deep ? 20 : libraries ~/ 4;

  /// Layers.
  int get layers => libraries ~/ width;

  /// A name for directories: `deep-2000`, `wide-5000-m38-flutter`.
  String get name => [
    shape.name,
    '$libraries',
    if (methods > 0) 'm$methods',
    if (flutter) 'flutter',
    if (packageTest) 'pkgtest',
  ].join('-');

  /// The package name of library [i] of layer [l].
  static String pkg(int l, int i) => 'p${l}_$i';

  /// The directory of a library, relative to the workspace root.
  static String dir(int l, int i) => 'l$l/${pkg(l, i)}';

  /// The three libraries of the layer below that library [i] of layer [l]
  /// imports.
  List<(int, int)> deps(int l, int i) => l == 0
      ? const []
      : [
          for (var k = 0; k < 3; k++)
            (l - 1, (i + k * (width ~/ 3 + 1)) % width),
        ];

  /// Methods needed for about [lines] lines over [libraries] libraries.
  static int methodsFor(int lines, int libraries) {
    final perLib = lines / libraries;
    final m = ((perLib - 20) / 6).round();
    return m < 0 ? 0 : m;
  }
}

/// The library edited by the edit flows: the leaf every top library reaches.
const leafDir = 'l0/p0_0';

/// The line a body edit goes after, in every generated library.
const bodyAnchor = 'int f(int x) {';

String _library(GraphSpec s, int l, int i) {
  final b = StringBuffer();
  final deps = s.deps(l, i);
  if (s.flutter) b.writeln("import 'package:flutter/widgets.dart';");
  for (final (dl, di) in deps) {
    final p = GraphSpec.pkg(dl, di);
    b.writeln("import 'package:$p/x.dart' as $p;");
  }
  b
    ..writeln()
    ..writeln('/// Model of ${GraphSpec.pkg(l, i)}.')
    ..writeln('class Model$l${'x'}$i {')
    ..writeln('  /// Creates a model.')
    ..writeln('  const Model$l${'x'}$i(this.id);')
    ..writeln()
    ..writeln('  /// The id.')
    ..writeln('  final int id;');
  for (var m = 0; m < s.methods; m++) {
    b
      ..writeln()
      ..writeln('  /// m$m.')
      ..writeln('  int m$m(int x) {')
      ..writeln('    final y = x * $m + id;')
      ..writeln('    return y.isEven ? y ~/ 2 : y + $m;')
      ..writeln('  }');
  }
  b
    ..writeln('}')
    ..writeln()
    ..writeln('/// f.')
    ..writeln(bodyAnchor)
    ..writeln('  var acc = Model$l${'x'}$i($i).id + x;');
  for (final (dl, di) in deps) {
    b.writeln('  acc += ${GraphSpec.pkg(dl, di)}.f(x);');
  }
  b
    ..writeln('  return acc;')
    ..writeln('}');
  if (s.flutter) {
    b
      ..writeln()
      ..writeln('/// The widget of ${GraphSpec.pkg(l, i)}.')
      ..writeln('class View$l${'x'}$i extends StatelessWidget {')
      ..writeln('  /// Creates the widget.')
      ..writeln('  const View$l${'x'}$i({super.key});')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Widget build(BuildContext context) =>')
      ..writeln("      Text('\${f(1)}', textDirection: TextDirection.ltr);")
      ..writeln('}');
  }
  return b.toString();
}

void _write(String root, String rel, String text) {
  final f = File('$root/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}

const _options = 'analyzer:\n  errors: {}\n';

/// The `.bazelrc` of a generated workspace: the settings rules_dart
/// recommends to a consumer, by absolute path, then the user file.
String _rc(String repo, {bool analysis = false}) =>
    'import $repo/rules_dart/dart/consumer.bazelrc\n'
    '${analysis ? 'common --@rules_dart//dart:analysis_config=//:analysis_config\n' : ''}'
    'try-import %workspace%/.bazelrc.user\n';

/// Writes the Bazel workspace of [s] at [out], using the rules of [repo].
///
/// A [lock] (a `pubspec.lock`) is copied in for the pub hub when the graph
/// needs one (Flutter, or tests with `package:test`); [seedLockfile] (a
/// `MODULE.bazel.lock` that already holds the hub's planning facts) is
/// copied in so the first evaluation asks no server.
void writeBazelGraph(
  GraphSpec s,
  String out,
  String repo, {
  String? lock,
  String? seedLockfile,
}) {
  final hub = s.flutter || s.packageTest;
  if (hub && lock == null) throw ArgumentError('this graph needs a lock');
  final module = StringBuffer()
    ..writeln('module(name = "bench_graph")')
    ..writeln()
    ..writeln(
      'bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")',
    )
    ..writeln(
      'local_path_override(module_name = "ai_rules_dart", path = "$repo/rules_dart")',
    );
  if (s.flutter) {
    module
      ..writeln(
        'bazel_dep(name = "ai_rules_flutter", version = "0.0.0", repo_name = "rules_flutter")',
      )
      ..writeln(
        'local_path_override(module_name = "ai_rules_flutter", path = "$repo/rules_flutter")',
      )
      ..writeln()
      ..writeln(
        'flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")',
      )
      ..writeln('flutter.toolchain(flutter_version = "3.47.7")')
      ..writeln('flutter.pub(name = "deps", lock = "//:pubspec.lock")')
      ..writeln('use_repo(flutter, "deps", "flutter_toolchains")')
      ..writeln('register_toolchains("@flutter_toolchains//:all")');
  } else {
    module
      ..writeln()
      ..writeln(
        'dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")',
      )
      ..writeln('dart.toolchain(dart_version = "3.13.5")')
      ..writeln('use_repo(dart, "dart_toolchains")')
      ..writeln('register_toolchains("@dart_toolchains//:all")');
    if (hub) {
      module
        ..writeln()
        ..writeln(
          'pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")',
        )
        ..writeln('pub.from_lock(name = "pub_deps", lock = "//:pubspec.lock")')
        ..writeln('use_repo(pub, "pub_deps")');
    }
  }
  Directory(out).createSync(recursive: true);
  _write(out, 'MODULE.bazel', module.toString());
  _write(out, '.bazelversion', '9.3.0\n');
  _write(out, '.bazelrc', _rc(repo, analysis: true));
  _write(out, 'analysis_options.yaml', _options);
  _write(
    out,
    'BUILD.bazel',
    'load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")\n\n'
        'exports_files(["pubspec.lock"])\n\n'
        'dart_analysis_config(name = "analysis_config", options = [":options"])\n\n'
        'dart_analysis_options(name = "options", src = "analysis_options.yaml")\n',
  );
  if (lock != null) File(lock).copySync('$out/pubspec.lock');
  if (seedLockfile != null)
    File(seedLockfile).copySync('$out/MODULE.bazel.lock');
  final rule = s.flutter ? 'flutter_library' : 'dart_library';
  final defs = s.flutter
      ? '@rules_flutter//flutter:defs.bzl'
      : '@rules_dart//dart:defs.bzl';
  for (var l = 0; l < s.layers; l++) {
    for (var i = 0; i < s.width; i++) {
      final dir = GraphSpec.dir(l, i);
      _write(out, '$dir/lib/x.dart', _library(s, l, i));
      final deps = [
        for (final (dl, di) in s.deps(l, i)) '"//${GraphSpec.dir(dl, di)}"',
        if (s.flutter) '"@deps//:flutter"',
      ];
      _write(
        out,
        '$dir/BUILD.bazel',
        'load("$defs", "$rule")\n\n'
            '$rule(\n'
            '    name = "${GraphSpec.pkg(l, i)}",\n'
            '    srcs = ["lib/x.dart"],\n'
            '    package_name = "${GraphSpec.pkg(l, i)}",\n'
            '    visibility = ["//visibility:public"],\n'
            '    deps = [${deps.join(', ')}],\n'
            ')\n',
      );
    }
  }
  final top = s.layers - 1;
  final tests = StringBuffer(
    'load("@rules_dart//dart:defs.bzl", "dart_test")\n',
  );
  for (var i = 0; i < s.width; i++) {
    _write(out, 'tests/test/t${i}_test.dart', _test(s, top, i));
    tests
      ..writeln()
      ..writeln('dart_test(')
      ..writeln('    name = "t${i}_test",')
      ..writeln('    main = "test/t${i}_test.dart",')
      ..writeln('    deps = [')
      ..writeln('        "//${GraphSpec.dir(top, i)}",')
      ..writeln(s.packageTest ? '        "@pub_deps//:test",' : '')
      ..writeln('    ],')
      ..writeln(')');
  }
  if (!s.flutter) _write(out, 'tests/BUILD.bazel', tests.toString());
  if (s.flutter) {
    _write(out, 'app/lib/main.dart', _main(s));
    _write(
      out,
      'app/BUILD.bazel',
      'load("@rules_flutter//flutter:defs.bzl", "flutter_application")\n\n'
          'flutter_application(\n'
          '    name = "app",\n'
          '    srcs = ["lib/main.dart"],\n'
          '    main = "lib/main.dart",\n'
          '    package_name = "app",\n'
          '    deps = [\n'
          '        "@deps//:flutter",\n'
          '${[for (var i = 0; i < s.width; i++) '        "//${GraphSpec.dir(top, i)}",\n'].join()}'
          '    ],\n'
          ')\n',
    );
  }
}

String _test(GraphSpec s, int top, int i) {
  final p = GraphSpec.pkg(top, i);
  return s.packageTest
      ? "import 'package:$p/x.dart' as d;\n"
            "import 'package:test/test.dart';\n\n"
            "void main() {\n  test('f', () {\n    expect(d.f(1), isNonZero);\n  });\n}\n"
      : "import 'package:$p/x.dart' as d;\n\nvoid main() {\n  d.f(1);\n}\n";
}

String _main(GraphSpec s) {
  final top = s.layers - 1;
  final b = StringBuffer("import 'package:flutter/widgets.dart';\n");
  for (var i = 0; i < s.width; i++) {
    final p = GraphSpec.pkg(top, i);
    b.writeln("import 'package:$p/x.dart' as $p;");
  }
  b
    ..writeln()
    ..writeln('void main() {')
    ..writeln('  runApp(')
    ..writeln('    const Column(')
    ..writeln('      children: [');
  for (var i = 0; i < s.width; i++) {
    b.writeln('        ${GraphSpec.pkg(top, i)}.View$top${'x'}$i(),');
  }
  b
    ..writeln('      ],')
    ..writeln('    ),')
    ..writeln('  );')
    ..writeln('}');
  return b.toString();
}

String _pubspec(
  String name, {
  List<String> deps = const [],
  bool flutter = false,
  List<String> dev = const [],
}) {
  final b = StringBuffer()
    ..writeln('name: $name')
    ..writeln('publish_to: none')
    ..writeln('resolution: workspace')
    ..writeln('environment:')
    ..writeln('  sdk: ^3.13.0');
  if (deps.isNotEmpty || flutter) {
    b.writeln('dependencies:');
    if (flutter)
      b
        ..writeln('  flutter:')
        ..writeln('    sdk: flutter');
    for (final d in deps) {
      b.writeln('  $d: any');
    }
  }
  if (dev.isNotEmpty) {
    b.writeln('dev_dependencies:');
    for (final d in dev) {
      b.writeln('  $d: any');
    }
  }
  return b.toString();
}

/// Writes the stock twin of [s] at [out]: a pub workspace with the same
/// libraries, a `tests` package (Dart) or an `app` package (Flutter), so
/// `dart analyze`, `dart test` and `flutter build` run on the same code.
/// [lock] is copied to the root so pub picks the versions the Bazel side
/// uses; run `dart pub get --offline` (or `flutter pub get --offline`) once.
void writeStockTwin(GraphSpec s, String out, {String? lock}) {
  final members = <String>[];
  Directory(out).createSync(recursive: true);
  for (var l = 0; l < s.layers; l++) {
    for (var i = 0; i < s.width; i++) {
      final dir = GraphSpec.dir(l, i);
      members.add(dir);
      _write(out, '$dir/lib/x.dart', _library(s, l, i));
      _write(
        out,
        '$dir/pubspec.yaml',
        _pubspec(
          GraphSpec.pkg(l, i),
          deps: [for (final (dl, di) in s.deps(l, i)) GraphSpec.pkg(dl, di)],
          flutter: s.flutter,
        ),
      );
    }
  }
  final top = s.layers - 1;
  final tops = [for (var i = 0; i < s.width; i++) GraphSpec.pkg(top, i)];
  if (s.flutter) {
    members.add('app');
    _write(out, 'app/lib/main.dart', _main(s));
    _write(out, 'app/pubspec.yaml', _pubspec('app', deps: tops, flutter: true));
  } else {
    members.add('tests');
    for (var i = 0; i < s.width; i++) {
      _write(out, 'tests/test/t${i}_test.dart', _test(s, top, i));
    }
    _write(
      out,
      'tests/pubspec.yaml',
      _pubspec('tests', deps: tops, dev: s.packageTest ? ['test'] : const []),
    );
  }
  final root = StringBuffer()
    ..writeln('name: bench_twin')
    ..writeln('publish_to: none')
    ..writeln('environment:')
    ..writeln('  sdk: ^3.13.0')
    ..writeln('workspace:');
  for (final m in members) {
    root.writeln('  - $m');
  }
  _write(out, 'pubspec.yaml', root.toString());
  _write(out, 'analysis_options.yaml', _options);
  if (lock != null) File(lock).copySync('$out/pubspec.lock');
}

/// Writes the per-source-file probe at [out]: two libraries of 10 and 20
/// source files, and a test over each, so the actions a target registers
/// per source file are the difference between the two divided by 10.
void writePerSourceProbe(String out, String repo) {
  Directory(out).createSync(recursive: true);
  _write(
    out,
    'MODULE.bazel',
    'module(name = "bench_per_source")\n\n'
        'bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")\n'
        'local_path_override(module_name = "ai_rules_dart", path = "$repo/rules_dart")\n\n'
        'dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")\n'
        'dart.toolchain(dart_version = "3.13.5")\n'
        'use_repo(dart, "dart_toolchains")\n'
        'register_toolchains("@dart_toolchains//:all")\n',
  );
  _write(out, '.bazelversion', '9.3.0\n');
  _write(out, '.bazelrc', _rc(repo, analysis: true));
  _write(out, 'analysis_options.yaml', _options);
  final build = StringBuffer(
    'load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options", "dart_library", "dart_test")\n\n'
    'dart_analysis_config(name = "analysis_config", options = [":options"])\n\n'
    'dart_analysis_options(name = "options", src = "analysis_options.yaml")\n',
  );
  for (final n in [10, 20]) {
    for (var i = 0; i < n; i++) {
      _write(
        out,
        'src$n/lib/a$i.dart',
        i == 0
            ? [for (var k = 1; k < n; k++) "import 'a$k.dart';"].join('\n') +
                  '\n\n/// f.\nint f() => ${[for (var k = 1; k < n; k++) 'f$k()'].join(' + ')};\n'
            : '/// f$i.\nint f$i() => $i;\n',
      );
    }
    _write(
      out,
      'src$n/BUILD.bazel',
      'load("@rules_dart//dart:defs.bzl", "dart_library")\n\n'
          'dart_library(\n'
          '    name = "src$n",\n'
          '    srcs = glob(["lib/*.dart"]),\n'
          '    package_name = "src$n",\n'
          '    visibility = ["//visibility:public"],\n'
          ')\n',
    );
    _write(
      out,
      't${n}_test.dart',
      "import 'package:src$n/a0.dart';\n\nvoid main() {\n  if (f() < 0) throw StateError('f');\n}\n",
    );
    build
      ..writeln()
      ..writeln('dart_test(')
      ..writeln('    name = "t${n}_test",')
      ..writeln('    main = "t${n}_test.dart",')
      ..writeln('    deps = ["//src$n"],')
      ..writeln(')');
  }
  _write(out, 'BUILD.bazel', build.toString());
}

/// Model files of the code generation package.
const codegenFiles = 200;

/// The relative path of model [i] of the code generation package.
String codegenModel(int i) => 'lib/src/m$i.dart';

String _model(int i) =>
    "import 'package:json_annotation/json_annotation.dart';\n\n"
    "import 'common.dart';\n\n"
    "part 'm$i.g.dart';\n\n"
    '/// Model $i.\n'
    '@JsonSerializable()\n'
    'class M$i {\n'
    '  /// Creates model $i.\n'
    '  M$i({required this.id, required this.name, this.tags = const [], this.kind = Kind.plain});\n\n'
    '  /// Reads model $i from JSON.\n'
    '  factory M$i.fromJson(Map<String, dynamic> json) => _\$M${i}FromJson(json);\n\n'
    '  /// The id.\n'
    '  final int id;\n\n'
    '  /// The name.\n'
    '  final String name;\n\n'
    '  /// The tags.\n'
    '  final List<String> tags;\n\n'
    '  /// The kind.\n'
    '  final Kind kind;\n\n'
    '  /// Writes model $i as JSON.\n'
    '  Map<String, dynamic> toJson() => _\$M${i}ToJson(this);\n'
    '}\n';

/// The package directory of the code generation workspace, relative to its
/// root (a `dart_build_runner` in the root package would glob Bazel's
/// `bazel-*` links, so the package sits below the root, as in the repository's
/// own e2e workspace).
const codegenPackage = 'models';

/// Writes the code generation package: [codegenFiles] models for
/// `json_serializable`. With [bazel] it is a Bazel workspace at [out] whose
/// package [codegenPackage] has a `dart_build_runner` target; without, a
/// stock package at [out] (`dart run build_runner build`). [lock] is a lock
/// with `build_runner`, `json_serializable` and `json_annotation`;
/// [seedLockfile] a `MODULE.bazel.lock` holding its planning facts.
void writeCodegenPackage(
  String out,
  String repo, {
  required String lock,
  bool bazel = true,
  String? seedLockfile,
}) {
  final pkg = bazel ? '$out/$codegenPackage' : out;
  Directory(pkg).createSync(recursive: true);
  _write(
    pkg,
    'pubspec.yaml',
    'name: models\npublish_to: none\nenvironment:\n  sdk: ^3.13.0\n'
        'dependencies:\n  json_annotation: any\n'
        'dev_dependencies:\n  build_runner: any\n  json_serializable: any\n',
  );
  _write(
    pkg,
    'build.yaml',
    'targets:\n  \$default:\n    builders:\n      json_serializable:\n'
        '        generate_for:\n          - lib/src/**\n',
  );
  _write(
    pkg,
    'lib/src/common.dart',
    '/// What a model is.\nenum Kind {\n  /// Plain.\n  plain,\n\n  /// Special.\n  special,\n}\n',
  );
  for (var i = 0; i < codegenFiles; i++) {
    _write(pkg, codegenModel(i), _model(i));
  }
  File(lock).copySync('$out/pubspec.lock');
  if (!bazel) return;
  _write(
    out,
    'MODULE.bazel',
    'module(name = "bench_codegen")\n\n'
        'bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")\n'
        'local_path_override(module_name = "ai_rules_dart", path = "$repo/rules_dart")\n\n'
        'dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")\n'
        'dart.toolchain(dart_version = "3.13.5")\n'
        'use_repo(dart, "dart_toolchains")\n'
        'register_toolchains("@dart_toolchains//:all")\n\n'
        'pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")\n'
        'pub.from_lock(name = "pub_deps", lock = "//:pubspec.lock")\n'
        'use_repo(pub, "pub_deps")\n',
  );
  _write(out, '.bazelversion', '9.3.0\n');
  _write(out, '.bazelrc', _rc(repo));
  _write(out, 'BUILD.bazel', 'exports_files(["pubspec.lock"])\n');
  final outs = [for (var i = 0; i < codegenFiles; i++) '"lib/src/m$i.g.dart"'];
  _write(
    pkg,
    'BUILD.bazel',
    'load("@rules_dart//dart:defs.bzl", "dart_build_runner", "dart_library")\n\n'
        'OUTS = [\n${outs.map((o) => '    $o,\n').join()}]\n\n'
        'dart_build_runner(\n'
        '    name = "gen",\n'
        '    outs = OUTS,\n'
        '    runner = "@pub_deps//build_runner",\n'
        '    deps = ["@pub_deps//:json_annotation"],\n'
        ')\n\n'
        'dart_library(\n'
        '    name = "models",\n'
        '    srcs = glob(["lib/**/*.dart"], exclude = OUTS) + [":" + o for o in OUTS],\n'
        '    package_name = "models",\n'
        '    deps = ["@pub_deps//:json_annotation"],\n'
        ')\n',
  );
  if (seedLockfile != null) {
    File(seedLockfile).copySync('$out/MODULE.bazel.lock');
  }
}
