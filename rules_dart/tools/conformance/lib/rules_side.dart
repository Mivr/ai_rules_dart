/// The rules side: the project copy with its overlay laid over it, built with
/// Bazel.
library;

import 'dart:convert';
import 'dart:io';

import 'package:conformance/layout.dart';
import 'package:conformance/projects.dart';
import 'package:conformance/proc.dart';
import 'package:conformance/records.dart';
import 'package:conformance/stock.dart';

/// How to reach the rules and the Bazel to build with.
class RulesSetup {
  const RulesSetup({
    required this.repoRoot,
    required this.bazel,
    this.androidBazelrc,
  });

  /// The repository holding `rules_dart/` and `rules_flutter/`; the overlay
  /// points both modules here.
  final String repoRoot;

  /// The Bazel command (a wrapper is fine).
  final List<String> bazel;

  /// An rc file imported by projects that build Android (the host's SDK and
  /// NDK), or null.
  final String? androidBazelrc;
}

/// Lays [overlay] over a fresh copy of [corpusProject] at [copy], and writes
/// `.bazelrc.user` pointing the rule modules at [setup]'s repository.
void prepareRulesCopy(
  ProjectSpec spec,
  Directory corpusProject,
  Directory overlay,
  Directory copy,
  RulesSetup setup,
) {
  freshCopy(spec, corpusProject, copy);
  copyTree(overlay, copy);
  File('${copy.path}/.bazelrc.user').writeAsStringSync(
    [
      'common --override_module=ai_rules_dart=${setup.repoRoot}/rules_dart',
      if (spec.flutter)
        'common --override_module=ai_rules_flutter=${setup.repoRoot}/rules_flutter',
      if (spec.android && setup.androidBazelrc != null)
        'import ${setup.androidBazelrc}',
      '',
    ].join('\n'),
  );
}

/// Builds every kind in [kinds] of [spec] with the rules.
Future<void> buildRules({
  required ProjectSpec spec,
  required Directory corpusProject,
  required Directory overlay,
  required String work,
  required List<Kind> kinds,
  required RulesSetup setup,
}) async {
  final copy = Directory('$work/rules/${spec.name}/src');
  prepareRulesCopy(spec, corpusProject, overlay, copy, setup);
  for (final kind in kinds) {
    final KindSpec? k = spec.kinds[kind];
    if (k == null) continue;
    final out = KindDir(work, Side.rules, spec.name, kind)..reset();
    out.writeStatus(await _buildKind(kind, k, copy, out, setup));
  }
}

Future<Status> _buildKind(
  Kind kind,
  KindSpec k,
  Directory copy,
  KindDir out,
  RulesSetup setup,
) async {
  Future<Run> bazel(List<String> args) =>
      run([...setup.bazel, ...args], cwd: copy.path, log: out.log);
  switch (kind) {
    case Kind.tests:
      return _tests(copy, out, bazel);
    case Kind.analysis:
      return _analysis(copy, out, bazel);
    case Kind.exe || Kind.web || Kind.apk || Kind.linux:
      final Run b = await bazel(['build', ...k.bazelFlags, k.target!]);
      if (!b.ok) {
        return Status(
          built: false,
          reason: b.failureLine(),
          commands: [b.display],
          seconds: b.seconds,
        );
      }
      final Run q = await bazel([
        'cquery',
        ...k.bazelFlags,
        '--output=files',
        k.target!,
      ]);
      final List<String> files = [
        for (final l in q.stdout.split('\n'))
          if (l.trim().isNotEmpty) '${copy.path}/${l.trim()}',
      ];
      final commands = [b.display, q.display];
      final String? picked = _pick(kind, files);
      if (picked == null) {
        return Status(
          built: false,
          reason: 'no ${kind.name} output among: ${files.join(' ')}',
          commands: commands,
          seconds: b.seconds,
        );
      }
      if (kind == Kind.exe) {
        final runs = <ExeRun>[];
        for (final args in k.inputs) {
          final Run p = await run(
            [picked, ...args],
            cwd: copy.path,
            log: out.log,
          );
          runs.add(ExeRun(args, p.stdout, p.stderr, p.exitCode));
        }
        writeJson(out.runs, [for (final x in runs) x.toJson()]);
      } else if (kind == Kind.apk) {
        File(picked).copySync(out.apk.path);
      } else {
        copyTree(Directory(picked), out.tree);
      }
      return Status(built: true, commands: commands, seconds: b.seconds);
  }
}

String? _pick(Kind kind, List<String> files) {
  for (final f in files) {
    final FileSystemEntityType t = FileSystemEntity.typeSync(f);
    switch (kind) {
      case Kind.apk when f.endsWith('.apk') && !f.endsWith('_unsigned.apk'):
        return f;
      case Kind.web || Kind.linux when t == FileSystemEntityType.directory:
        return f;
      case Kind.exe when t == FileSystemEntityType.file:
        return f;
      default:
        continue;
    }
  }
  return null;
}

Future<Status> _tests(
  Directory copy,
  KindDir out,
  Future<Run> Function(List<String>) bazel,
) async {
  final Run q = await bazel(['query', 'tests(//...)', '--output=label']);
  final List<String> labels = [
    for (final l in q.stdout.split('\n'))
      if (l.startsWith('//')) l.trim(),
  ];
  if (labels.isEmpty) {
    return Status(
      built: false,
      reason: q.ok ? 'no test targets' : q.failureLine(),
      commands: [q.display],
    );
  }
  final bep = File('${out.dir.path}/bep.json');
  final Run t = await bazel([
    'test',
    '--keep_going',
    '--build_event_json_file=${bep.path}',
    ...labels,
  ]);
  final Map<String, String> reports = bep.existsSync()
      ? testReportsFromBuildEvents(bep.readAsLinesSync())
      : const {};
  final records = <TestRecord>[];
  final notes = <String>[];
  for (final label in labels) {
    final String? xml = reports[label];
    if (xml == null || !File(xml).existsSync()) {
      notes.add('$label: no test report (did not build or run)');
      continue;
    }
    records.addAll(
      testsFromJunit(File(xml).readAsStringSync(), fallbackSuite: label),
    );
  }
  writeJson(out.tests, [for (final r in records) r.toJson()]);
  return Status(
    built: records.isNotEmpty,
    reason: t.ok ? null : t.failureLine(),
    commands: [q.display, t.display],
    seconds: t.seconds,
    notes: notes,
  );
}

Future<Status> _analysis(
  Directory copy,
  KindDir out,
  Future<Run> Function(List<String>) bazel,
) async {
  final Run q = await bazel([
    'query',
    'labels(srcs, //...) union labels(main, //...)',
    '--output=label',
  ]);
  final List<String> files = [
    for (final l in q.stdout.split('\n'))
      if (l.startsWith('//') && l.trim().endsWith('.dart'))
        _labelPath(l.trim()),
  ]..sort();
  final Run b = await bazel([
    'build',
    '--keep_going',
    '--aspects=@rules_dart//dart:analyze.bzl%dart_analyze',
    '--output_groups=dart_analyze',
    '--@rules_dart//dart:analysis_config=//:analysis_config',
    '//...',
  ]);
  final List<Diagnostic> found = diagnosticsFromText(
    '${b.stdout}\n${b.stderr}'.split('\n'),
  );
  final bool ran = b.ok || found.isNotEmpty;
  writeJson(out.diagnostics, {
    'files': files,
    'diagnostics': [for (final d in found) d.toJson()],
  });
  return Status(
    built: ran,
    reason: ran ? null : b.failureLine(),
    commands: [q.display, b.display],
    seconds: b.seconds,
  );
}

/// The `test.xml` of each test target in Bazel's build event JSON
/// (`--build_event_json_file`), by label: the reports of this run, cached
/// ones included. A target that did not build has none. With several shards
/// or attempts, the last one listed wins.
Map<String, String> testReportsFromBuildEvents(Iterable<String> lines) {
  final reports = <String, String>{};
  for (final line in lines) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, Object?>) continue;
    final id = event['id'];
    final result = event['testResult'];
    if (id is! Map<String, Object?> || result is! Map<String, Object?>) {
      continue;
    }
    final label = (id['testResult'] as Map<String, Object?>?)?['label'];
    for (final o in result['testActionOutput'] as List? ?? const []) {
      final output = o as Map<String, Object?>;
      final uri = output['uri'] as String? ?? '';
      if (output['name'] == 'test.xml' && uri.startsWith('file://')) {
        reports['$label'] = Uri.parse(uri).toFilePath();
      }
    }
  }
  return reports;
}

/// `//pkg:dir/a.dart` becomes `pkg/dir/a.dart`.
String _labelPath(String label) {
  final String rest = label.substring(2);
  final int colon = rest.indexOf(':');
  final String pkg = colon < 0 ? rest : rest.substring(0, colon);
  final String name = colon < 0 ? '' : rest.substring(colon + 1);
  return pkg.isEmpty ? name : '$pkg/$name';
}
