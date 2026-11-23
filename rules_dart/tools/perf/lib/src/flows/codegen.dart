/// Code generation of a 200-file `json_serializable` package:
/// `dart_build_runner` against stock `dart run build_runner build`.
library;

import 'dart:io';

import '../bazel.dart';
import '../flow.dart';
import '../generate.dart';
import '../proc.dart';
import 'common.dart';

/// Makes (once) the stock package and the Bazel workspace of the same
/// sources; the stock `pub get` writes the lock both use.
Future<({String bazel, String stock})> codegenWorkspaces(Ctx c) async {
  final stock = '${c.scratch}/gen/codegen-stock';
  final bazel = '${c.scratch}/gen/codegen';
  final e2e = '${c.repo}/rules_dart/e2e/build_runner';
  if (!File('$stock/.bench-generated').existsSync()) {
    rmrf(stock);
    writeCodegenPackage(stock, c.repo, lock: '$e2e/pubspec.lock', bazel: false);
    await must(
      c.stock(['dart', 'pub', 'get', '--offline'], stock),
      log: c.log('generate'),
    );
    File('$stock/.bench-generated').writeAsStringSync('');
  }
  if (!File('$bazel/.bench-generated').existsSync()) {
    rmrf(bazel);
    writeCodegenPackage(
      bazel,
      c.repo,
      lock: '$stock/pubspec.lock',
      seedLockfile: File('$e2e/MODULE.bazel.lock').existsSync()
          ? '$e2e/MODULE.bazel.lock'
          : null,
    );
    File('$bazel/.bench-generated').writeAsStringSync('');
  }
  File('$bazel/.bazelrc.user')
      .writeAsStringSync('${c.bazelrcLines.join('\n')}\n');
  return (bazel: bazel, stock: stock);
}

/// One code generation state for one side.
final class CodegenFlow extends Flow {
  /// [state] is `cold` (fresh server and worker, no caches; stock: no
  /// `.dart_tool/build`, no outputs), `warm` (every model edited, worker
  /// live) or `edit` (one model gains a field).
  CodegenFlow(this.state, {required this.stock});

  @override
  final String state;

  /// Which side.
  final bool stock;

  @override
  String get id => 'codegen.$state.${stock ? 'stock' : 'rules'}';
  @override
  String get tool => stock ? 'stock' : 'rules_dart';
  @override
  String get corpus => 'gen-codegen-$codegenFiles';
  @override
  String get flow => 'codegen';
  @override
  bool get warm => !stock && state != 'cold';
  @override
  Set<String> get tags => {if (stock) 'stock'};

  late String _ws;
  Bazel? _b;
  final _edited = <String, String>{};

  @override
  Bazel? get server => _b;

  List<String> get _stockBuild => const [
    'dart',
    'run',
    'build_runner',
    'build',
    '--delete-conflicting-outputs',
  ];

  @override
  String describe(Ctx c) =>
      '${stock ? _stockBuild.join(' ') : 'bazel build //$codegenPackage:gen'}; ${switch (state) {
        'cold' => stock ? 'before each run: .dart_tool/build and every *.g.dart removed' : 'before each run: bazel shutdown and clean; --disk_cache= on the build',
        'warm' => 'before each run: a comment with a new number appended to all $codegenFiles models',
        _ => 'before each run: one model (m7) gains a field with a new name',
      }}; ${stock ? 'time: wall clock' : 'time: Bazel elapsed'}';

  @override
  Future<void> setUp(Ctx c) async {
    final w = await codegenWorkspaces(c);
    _ws = stock ? w.stock : w.bazel;
    if (stock) {
      await _run(c, mustPass: true);
    } else {
      _b = c.bazelIn(_ws, id);
      await _b!.must(['build', '//$codegenPackage:gen']);
    }
  }

  Future<Done> _run(Ctx c, {bool mustPass = false}) async {
    final d = await runCmd(c.stock(_stockBuild, _ws), log: c.log(id));
    if (mustPass && !d.ok) throw StateError('build_runner failed: ${d.tail()}');
    return d;
  }

  /// The package directory: the workspace root on the stock side.
  String get _pkg => stock ? _ws : '$_ws/$codegenPackage';

  void _write(String rel, String Function(String) change) {
    final f = File('$_pkg/$rel');
    final original = _edited[rel] ??= f.readAsStringSync();
    f.writeAsStringSync(change(original));
  }

  @override
  Future<void> prepare(Ctx c, int run) async {
    switch (state) {
      case 'cold':
        if (stock) {
          rmrf('$_ws/.dart_tool/build');
          for (var i = 0; i < codegenFiles; i++) {
            rmrf('$_ws/lib/src/m$i.g.dart');
          }
        } else {
          await _b!.must(['shutdown']);
          await _b!.must(['clean']);
        }
      case 'warm':
        final n = c.fresh();
        for (var i = 0; i < codegenFiles; i++) {
          _write(codegenModel(i), (s) => '$s// bench $n\n');
        }
      default:
        final n = c.fresh();
        _write(
          codegenModel(7),
          (s) => s.replaceFirst(
            '  /// The kind.\n',
            '  /// Bench.\n  int bench$n = 0;\n\n  /// The kind.\n',
          ),
        );
    }
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    if (stock) {
      final d = await _run(c);
      if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
      return Measured(d.seconds);
    }
    final execLog = '${c.scratch}/logs/$id.exec.json';
    final d = await _b!.run([
      'build',
      if (state == 'cold') '--disk_cache=',
      '--execution_log_json_file=$execLog',
      '//$codegenPackage:gen',
    ]);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    return Measured(
      elapsedSeconds(d.stderr) ?? d.seconds,
      mnemonics: mnemonicsOfFile(execLog),
    );
  }

  @override
  Future<void> tearDown(Ctx c) async {
    for (final MapEntry(:key, :value) in _edited.entries) {
      File('$_pkg/$key').writeAsStringSync(value);
    }
    _edited.clear();
  }
}
