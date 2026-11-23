/// The two shapes most flows take: a Bazel command in a workspace, and a
/// stock-tool command in the stock copy of the same project.
library;

import 'dart:io';

import '../bazel.dart';
import '../flow.dart';
import '../proc.dart';
import '../workspace.dart';

/// Where a flow's workspace comes from: made (copied or generated) on first
/// use and kept.
typedef WorkspaceFn = Future<String> Function(Ctx c);

/// How an edit changes a file, given a fresh number.
enum EditKind {
  /// A statement inserted after the anchor line (a body edit).
  body,

  /// A public declaration appended (an API edit).
  api,

  /// A private Kotlin function appended.
  kotlin,

  /// The anchor text replaced by [EditSpec.to] with `{n}` the number.
  replace,
}

/// One edit, applied with a new number before every run and undone at the
/// end.
final class EditSpec {
  /// An edit of [file] (relative to the workspace).
  const EditSpec(this.file, this.kind, {this.anchor, this.to});

  /// The edited file, relative to the workspace root.
  final String file;

  /// What the edit does.
  final EditKind kind;

  /// The line a body edit goes after, or the text a replace edit replaces.
  final String? anchor;

  /// What a replace edit writes, with `{n}` for the number.
  final String? to;

  /// The edit in words, for the notes.
  String get describe => switch (kind) {
    EditKind.body => 'body edit in $file (a new local after "$anchor")',
    EditKind.api => 'API edit in $file (a public function appended)',
    EditKind.kotlin => 'Kotlin edit in $file (a private function appended)',
    EditKind.replace => 'edit in $file ("$anchor" becomes "$to")',
  };
}

/// The files of one workspace an [EditSpec] list touched.
final class Edits {
  final Map<String, Edited> _files = {};

  /// Applies [spec] in [root] with the number [n].
  void apply(String root, EditSpec spec, int n) {
    final path = resolveGlob('$root/${spec.file}');
    final f = _files[path] ??= Edited(path);
    switch (spec.kind) {
      case EditKind.body:
        f.insertAfter(spec.anchor!, dartBodyLine(n));
      case EditKind.api:
        f.append(dartApiDecl(n));
      case EditKind.kotlin:
        f.append(kotlinDecl(n));
      case EditKind.replace:
        f.replace(spec.anchor!, spec.to!.replaceAll('{n}', '$n'));
    }
  }

  /// Restores every touched file.
  void restore() {
    for (final f in _files.values) {
      f.restore();
    }
    _files.clear();
  }
}

/// A Bazel command in a workspace, timed by Bazel's own "Elapsed time" (it
/// leaves out a wait for a build slot of a wrapper), with the actions that
/// ran from the execution log.
final class BazelFlow extends Flow {
  /// A Bazel flow.
  BazelFlow({
    required this.id,
    required this.tool,
    required this.corpus,
    required this.flow,
    required this.state,
    required this.tags,
    required this.workspace,
    required this.command,
    required this.targets,
    this.edits = const [],
    this.warm = false,
    this.clean = false,
    this.cleanArgs = const [],
    this.warmUp = true,
    this.setUpSteps = const [],
    this.extraPrepare,
  });

  @override
  final String id;
  @override
  final String tool;
  @override
  final String corpus;
  @override
  final String flow;
  @override
  final String state;
  @override
  final Set<String> tags;
  @override
  final bool warm;

  /// The workspace.
  final WorkspaceFn workspace;

  /// The command and its flags (`['build', '-c', 'dbg']`).
  final List<String> command;

  /// The targets (or query) after the flags.
  final List<String> targets;

  /// Edits made before each run.
  final List<EditSpec> edits;

  /// `bazel clean` before each run (plus [cleanArgs] on the timed command).
  final bool clean;

  /// Flags the timed command adds in a clean flow (`--disk_cache=`).
  final List<String> cleanArgs;

  /// Whether set-up builds the targets once, so the first run is warm.
  final bool warmUp;

  /// Bazel commands run once at set-up, before the warm-up.
  final List<List<String>> setUpSteps;

  /// Anything else to do before a run (untimed).
  final Future<void> Function(Ctx c, String ws, int run)? extraPrepare;

  late String _ws;
  Bazel? _bazel;
  final _edits = Edits();

  @override
  Bazel? get server => _bazel;

  @override
  String describe(Ctx c) => [
    'bazel ${[...command, if (clean) ...cleanArgs, ...targets].join(' ')}',
    if (edits.isNotEmpty)
      'before each run: ${edits.map((e) => e.describe).join(', ')} with a new number',
    if (clean)
      'before each run: bazel clean${cleanArgs.isEmpty ? '' : ' (and ${cleanArgs.join(' ')} on the build)'}',
    if (!clean && edits.isEmpty) 'nothing changed between runs',
    'time: Bazel "Elapsed time"',
  ].join('; ');

  @override
  Future<void> setUp(Ctx c) async {
    _ws = await workspace(c);
    final b = _bazel = c.bazelIn(_ws, id);
    for (final step in setUpSteps) {
      await b.must(step);
    }
    if (warmUp) await b.must([...command, ...targets]);
    // Two edited builds, untimed, so the timed runs find workers that have
    // served requests already (on this machine the first DartKernelLink
    // worker of a server is destroyed when it is borrowed the second time).
    if (warm && edits.isNotEmpty) {
      for (var i = 0; i < 2; i++) {
        for (final e in edits) {
          _edits.apply(_ws, e, c.fresh());
        }
        await b.must([...command, ...targets]);
      }
    }
  }

  @override
  Future<void> prepare(Ctx c, int run) async {
    if (clean) await _bazel!.must(['clean']);
    for (final e in edits) {
      _edits.apply(_ws, e, c.fresh());
    }
    await extraPrepare?.call(c, _ws, run);
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final execLog = '${c.scratch}/logs/$id.exec.json';
    final done = await _bazel!.run([
      ...command,
      if (clean) ...cleanArgs,
      '--execution_log_json_file=$execLog',
      ...targets,
    ]);
    if (!done.ok) {
      throw StateError('run ${run + 1} failed: ${done.tail()}');
    }
    return Measured(
      elapsedSeconds(done.stderr) ?? done.seconds,
      mnemonics: mnemonicsOfFile(execLog),
      extra: {'client_wall_s': double.parse(done.seconds.toStringAsFixed(3))},
    );
  }

  @override
  Future<void> tearDown(Ctx c) async => _edits.restore();
}

/// A stock-tool command in the stock copy of a project, timed by its wall
/// clock.
final class StockFlow extends Flow {
  /// A stock flow.
  StockFlow({
    required this.id,
    required this.corpus,
    required this.flow,
    required this.state,
    required this.tags,
    required this.workspace,
    required this.argv,
    this.cwd = '',
    this.edits = const [],
    this.setUpSteps = const [],
    this.prepareSteps = const [],
    this.warmUp = true,
    this.env = const {},
  });

  @override
  final String id;
  @override
  String get tool => 'stock';
  @override
  final String corpus;
  @override
  final String flow;
  @override
  final String state;
  @override
  final Set<String> tags;

  /// The stock copy.
  final WorkspaceFn workspace;

  /// The timed command.
  final List<String> argv;

  /// The directory to run in, relative to the workspace.
  final String cwd;

  /// Edits made before each run.
  final List<EditSpec> edits;

  /// Commands run once at set-up (`flutter pub get --offline`).
  final List<List<String>> setUpSteps;

  /// Commands run before each run (`flutter clean`, ...).
  final List<List<String>> prepareSteps;

  /// Whether set-up runs [argv] once.
  final bool warmUp;

  /// Variables added for every command.
  ///
  /// In these, [argv] and the steps, `{scratch}` stands for the scratch
  /// directory.
  final Map<String, String> env;

  late String _ws;
  final _edits = Edits();

  String get _dir => cwd.isEmpty ? _ws : '$_ws/$cwd';

  @override
  String describe(Ctx c) => [
    argv.join(' '),
    if (cwd.isNotEmpty) 'in $cwd',
    if (prepareSteps.isNotEmpty)
      'before each run: ${prepareSteps.map((s) => s.join(' ')).join(', ')}',
    if (edits.isNotEmpty)
      'before each run: ${edits.map((e) => e.describe).join(', ')} with a new number',
    'stock environment of --stock-env; time: wall clock of the command',
  ].join('; ');

  Future<Done> _run(Ctx c, List<String> a) {
    String sub(String s) => s.replaceAll('{scratch}', c.scratch);
    return runCmd(
      c.stock(
        [for (final s in a) sub(s)],
        _dir,
        env: env.map((k, v) => MapEntry(k, sub(v))),
      ),
      log: c.log(id),
    );
  }

  Future<void> _must(Ctx c, List<String> a) async {
    final d = await _run(c, a);
    if (!d.ok) throw StateError('${a.join(' ')} failed: ${d.tail()}');
  }

  @override
  Future<void> setUp(Ctx c) async {
    _ws = await workspace(c);
    for (final s in setUpSteps) {
      await _must(c, s);
    }
    if (warmUp) await _must(c, argv);
  }

  @override
  Future<void> prepare(Ctx c, int run) async {
    for (final s in prepareSteps) {
      await _must(c, s);
    }
    for (final e in edits) {
      _edits.apply(_ws, e, c.fresh());
    }
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final d = await _run(c, argv);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    return Measured(d.seconds);
  }

  @override
  Future<void> tearDown(Ctx c) async => _edits.restore();
}

/// A flow this host cannot run (iOS, Linux desktop with the stock tool).
final class UnavailableFlow extends Flow {
  /// A row that says why [id] cannot run here.
  UnavailableFlow({
    required this.id,
    required this.tool,
    required this.corpus,
    required this.flow,
    required this.state,
    required this.reason,
  });

  @override
  final String id;
  @override
  final String tool;
  @override
  final String corpus;
  @override
  final String flow;
  @override
  final String state;

  /// Why not.
  final String reason;

  @override
  Set<String> get tags => const {'unavailable'};

  @override
  String describe(Ctx c) => 'not run';

  @override
  Future<void> setUp(Ctx c) async => throw NotAvailable(reason);

  @override
  Future<Measured> measure(Ctx c, int run) async => throw NotAvailable(reason);
}

/// [path] with each segment holding `*` replaced by the first matching
/// entry of its directory (a versioned directory name, say).
String resolveGlob(String path) {
  final parts = path.split('/');
  var out = parts.first;
  for (final part in parts.skip(1)) {
    if (!part.contains('*')) {
      out = '$out/$part';
      continue;
    }
    final re = RegExp('^${RegExp.escape(part).replaceAll(r'\*', '.*')}\$');
    final names = [
      for (final e in Directory(out).listSync())
        e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    ]..sort();
    final hit = names.firstWhere(
      re.hasMatch,
      orElse: () => throw StateError('nothing in $out matches $part'),
    );
    out = '$out/$hit';
  }
  return out;
}

/// Deletes [path] if it exists.
void rmrf(String path) {
  final t = FileSystemEntity.typeSync(path, followLinks: false);
  if (t == FileSystemEntityType.notFound) return;
  if (t == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else {
    File(path).deleteSync();
  }
}
