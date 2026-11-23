/// Shared fixtures for the incremental frontend-server worker tests.
///
/// `incr_fkc_worker_test.dart`, `incr_fkc_staging_test.dart` and
/// `incr_fkc_define_flagfiles_test.dart` drive the worker through the same
/// scripted compiler session and the same temp-dir workspace, so those live
/// here instead of being copied into each file. Nothing in this library
/// asserts; the tests own every `expect`.
library;

import 'dart:collection';
import 'dart:io';

import '../incr_fkc_server.dart';

/// A [CompilerSession] that replays a scripted queue of [CompileResult]s,
/// writes [dillBytes] to [fullDill] on every compile, and records each
/// command it receives in [commands].
class FakeSession implements CompilerSession {
  new({
    required this.fullDill,
    required this.dillBytes,
    List<CompileResult> script = const [],
    Queue<CompileResult>? shared,
  }) : _script = shared ?? Queue.of(script);

  /// Path the fake writes its dill bytes to on every compile.
  final String fullDill;

  /// Bytes written to [fullDill] on every compile or recompile.
  final List<int> dillBytes;
  final Queue<CompileResult> _script;

  /// Every command the session received, in order.
  final List<String> commands = [];

  /// Whether [close] was called.
  bool closed = false;

  /// Set by a test to simulate a crashed frontend server.
  bool dead = false;

  CompileResult _next(String command) {
    commands.add(command);
    File(fullDill).parent.createSync(recursive: true);
    File(fullDill).writeAsBytesSync(dillBytes);
    if (_script.isNotEmpty) return _script.removeFirst();
    return (errors: 0, diagnostics: const [], depLines: const []);
  }

  @override
  Future<CompileResult> compile(String entry) async => _next('compile $entry');

  @override
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  }) async => _next(
    '${resetFirst ? 'reset+' : ''}recompile $entry [${uris.join(',')}]',
  );

  @override
  Future<void> accept() async {
    commands.add('accept');
  }

  @override
  Future<void> reject() async {
    commands.add('reject');
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  bool get alive => !dead && !closed;
}

/// A workspace with a manifest, sources, staged copies, and the files the
/// compiler may read, all under a fresh temp dir used as the worker's cwd.
class Harness {
  new(this.dir);

  /// The temp directory used as the worker's cwd.
  final Directory dir;

  /// The workspace path.
  String get cwd => dir.path;

  /// Writes [content] to [rel] under [dir], creating parent directories.
  void write(String rel, String content) {
    File('${dir.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Writes `manifest.txt` listing the sources, stage, reads and output.
  void writeManifest() {
    write(
      'manifest.txt',
      [
        'lib/main.dart',
        'lib/a.dart',
        '# staged',
        'stage/lib/main.dart',
        'stage/lib/a.dart',
        '# allowed-reads',
        'pkg_config.json',
        'platform.dill',
        '# filesystem-roots',
        'stage',
        '# output',
        'out/app.dill',
      ].join('\n'),
    );
  }

  /// Writes sources, staged copies and read files that compile cleanly.
  void writeCleanSources() {
    write('lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('lib/a.dart', 'int get answer => 42;\n');
    write('stage/lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('stage/lib/a.dart', 'int get answer => 42;\n');
    write('pkg_config.json', '{}\n');
    write('platform.dill', 'platform\n');
  }

  /// The worker argv that points at `manifest.txt` and the fake VM.
  List<String> get argv => [
    '--declared-inputs',
    'manifest.txt',
    '--',
    'fake-vm',
    '--output-dill',
    'out/app.dill',
    '--filesystem-root',
    'stage',
    '--packages',
    'pkg_config.json',
    'package:app/main.dart',
  ];

  /// A copy of [argv] with the `--filesystem-root` value replaced by [root].
  List<String> argvWithRoot(String root) {
    final List<String> args = argv;
    args[args.indexOf('--filesystem-root') + 1] = root;
    return args;
  }

  /// The input paths a compile is expected to hash.
  List<String> get inputs => [
    'manifest.txt',
    'lib/main.dart',
    'lib/a.dart',
    'stage/lib/main.dart',
    'stage/lib/a.dart',
    'pkg_config.json',
    'platform.dill',
  ];

  /// The `+file://` dependency lines a clean compile reports.
  List<String> depLines() => [
    '+file://$cwd/lib/main.dart',
    '+file://$cwd/lib/a.dart',
    '+file://$cwd/stage/lib/main.dart',
    '+file://$cwd/stage/lib/a.dart',
    '+file://$cwd/pkg_config.json',
    '+file://$cwd/platform.dill',
  ];

  /// A clean [CompileResult] reporting [depLines].
  CompileResult ok() =>
      (errors: 0, diagnostics: const [], depLines: depLines());
}

/// Whether [parent] holds a surviving `incr_fkc_*` worker temp directory.
bool hasWorkerTemp(Directory parent) =>
    parent.listSync().whereType<Directory>().any(
      (d) => d.path.split(Platform.pathSeparator).last.startsWith('incr_fkc_'),
    );
