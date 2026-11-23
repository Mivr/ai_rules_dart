/// The stock side: the commands a developer runs, in a copy of the project.
library;

import 'dart:io';

import 'package:conformance/layout.dart';
import 'package:conformance/projects.dart';
import 'package:conformance/proc.dart';
import 'package:conformance/records.dart';
import 'package:conformance/tree.dart';

/// Top-level entries of a corpus project that are never copied: build
/// outputs and tool caches left by earlier runs, and version control.
const Set<String> skipOnCopy = {
  'build',
  '.dart_tool',
  '.git',
  '.gradle',
  'bazel-bin',
  'bazel-out',
  'bazel-testlogs',
};

/// Makes a fresh copy of [corpusProject] at [copy] and applies the
/// project's `prepare` copies.
void freshCopy(ProjectSpec spec, Directory corpusProject, Directory copy) {
  if (copy.existsSync()) copy.deleteSync(recursive: true);
  final skip = {...skipOnCopy};
  for (final e in corpusProject.listSync()) {
    final String name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (name.startsWith('bazel-')) skip.add(name);
  }
  copyTree(corpusProject, copy, skip: skip);
  for (final MapEntry(key: to, value: from) in spec.prepare.entries) {
    File('${copy.path}/$from').copySync('${copy.path}/$to');
  }
}

/// Builds every kind in [kinds] of [spec] with the stock tools.
Future<void> buildStock({
  required ProjectSpec spec,
  required Directory corpusProject,
  required String work,
  required List<Kind> kinds,
}) async {
  final copy = Directory('$work/stock/${spec.name}/src');
  freshCopy(spec, corpusProject, copy);
  final prepLog = File('$work/stock/${spec.name}/prepare.log');
  if (prepLog.existsSync()) prepLog.deleteSync();
  final Run pub = await run(
    [...spec.tool, 'pub', 'get', '--enforce-lockfile'],
    cwd: copy.path,
    log: prepLog,
  );
  for (final kind in kinds) {
    final KindSpec? k = spec.kinds[kind];
    if (k == null) continue;
    final out = KindDir(work, Side.stock, spec.name, kind)..reset();
    if (!pub.ok) {
      out.writeStatus(
        Status(
          built: false,
          reason: 'pub get failed: ${pub.failureLine()}',
          commands: [pub.display],
        ),
      );
      continue;
    }
    out.writeStatus(await _buildKind(kind, k, copy, out));
  }
}

Future<Status> _buildKind(
  Kind kind,
  KindSpec k,
  Directory copy,
  KindDir out,
) async {
  final Run r = await run(k.stock, cwd: copy.path, log: out.log);
  final commands = [r.display];
  switch (kind) {
    case Kind.tests:
      final List<TestRecord> records = testsFromJsonReporter(
        r.stdout.split('\n'),
      );
      writeJson(out.tests, [for (final t in records) t.toJson()]);
      return Status(
        built: records.isNotEmpty,
        reason: records.isEmpty ? r.failureLine() : null,
        commands: commands,
        seconds: r.seconds,
      );
    case Kind.analysis:
      final List<Diagnostic> found = diagnosticsFromText(
        '${r.stdout}\n${r.stderr}'.split('\n'),
      );
      // `dart analyze` exits non-zero when it finds something; it failed only
      // when it found nothing and still did not succeed.
      final bool ran = r.ok || found.isNotEmpty;
      writeJson(out.diagnostics, {
        'files': stockAnalyzedFiles(copy),
        'diagnostics': [for (final d in found) d.toJson()],
      });
      return Status(
        built: ran,
        reason: ran ? null : r.failureLine(),
        commands: commands,
        seconds: r.seconds,
      );
    case Kind.exe:
      if (!r.ok) return _failed(r, commands);
      final runs = <ExeRun>[];
      for (final args in k.inputs) {
        final Run p = await run(
          ['${copy.path}/${k.stockOutput}', ...args],
          cwd: copy.path,
          log: out.log,
        );
        runs.add(ExeRun(args, p.stdout, p.stderr, p.exitCode));
      }
      writeJson(out.runs, [for (final x in runs) x.toJson()]);
      return Status(built: true, commands: commands, seconds: r.seconds);
    case Kind.web || Kind.linux:
      if (!r.ok) return _failed(r, commands);
      copyTree(Directory('${copy.path}/${k.stockOutput}'), out.tree);
      return Status(built: true, commands: commands, seconds: r.seconds);
    case Kind.apk:
      if (!r.ok) return _failed(r, commands);
      File('${copy.path}/${k.stockOutput}').copySync(out.apk.path);
      return Status(built: true, commands: commands, seconds: r.seconds);
  }
}

Status _failed(Run r, List<String> commands) => Status(
  built: false,
  reason: r.failureLine(),
  commands: commands,
  seconds: r.seconds,
);

/// The Dart files `dart analyze` looks at in [copy]: everything outside
/// hidden directories and `build/`.
List<String> stockAnalyzedFiles(Directory copy) => [
  for (final f in listFiles(copy))
    if (f.endsWith('.dart') &&
        !f.startsWith('build/') &&
        !f.split('/').any((s) => s.startsWith('.')))
      f,
];
