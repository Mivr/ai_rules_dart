/// Builds the corpus with the stock tools and with the rules, compares the
/// outputs, and prints a parity score per project and kind of output.
///
///     bazel run //conformance -- --corpus=DIR --work=DIR
///         [--projects=counter,dart_pkg] [--kinds=tests,web]
///         [--steps=stock,rules,compare] [--ledger=FILE]
///         [--bazel=CMD] [--android-bazelrc=FILE]
///         [--root=DIR] [--by-design=FILE] [--overlays=DIR]
///         [--commit=SHA] [--date=YYYY-MM-DD]
///
/// The stock side needs the stock SDK on `PATH` (and `JAVA_HOME`,
/// `ANDROID_HOME`, `ANDROID_NDK_HOME` for Android, which the comparison of
/// APKs needs too). The corpus is never written: each side works on its own
/// copy under `--work`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:conformance/apk.dart';
import 'package:conformance/by_design.dart';
import 'package:conformance/compare.dart';
import 'package:conformance/layout.dart';
import 'package:conformance/proc.dart';
import 'package:conformance/projects.dart';
import 'package:conformance/report.dart';
import 'package:conformance/rules_side.dart';
import 'package:conformance/stock.dart';
import 'package:inventory/cli.dart';

const _steps = {'stock', 'rules', 'compare'};

Future<void> main(List<String> args) async {
  try {
    exit(await _main(args));
  } on FormatException catch (e) {
    stderr.writeln('conformance: ${e.message}');
    exit(2);
  }
}

Future<int> _main(List<String> args) async {
  final flags = Flags.parse(args, {
    'android-bazelrc',
    'bazel',
    'by-design',
    'commit',
    'corpus',
    'date',
    'kinds',
    'ledger',
    'overlays',
    'projects',
    'root',
    'steps',
    'work',
  });
  final String corpus = _required(flags, 'corpus');
  final String work = Directory(_required(flags, 'work')).absolute.path;
  final String root = repositoryRoot(flags);
  final String tool = '$root/rules_dart/tools/conformance';
  final List<String> names = _list(flags, 'projects') ?? projects.keys.toList();
  for (final n in names) {
    if (!projects.containsKey(n)) throw FormatException('unknown project: $n');
  }
  final List<Kind>? onlyKinds = _list(flags, 'kinds')?.map(Kind.parse).toList();
  final Set<String> steps = (_list(flags, 'steps') ?? _steps.toList()).toSet();
  if (!_steps.containsAll(steps)) {
    throw FormatException('--steps takes ${_steps.join(',')}');
  }
  final setup = RulesSetup(
    repoRoot: root,
    bazel: (flags.value('bazel') ?? 'bazel').split(' '),
    androidBazelrc: flags.value('android-bazelrc'),
  );
  final String overlays = flags.value('overlays') ?? '$tool/overlays';

  for (final name in names) {
    final ProjectSpec spec = projects[name]!;
    final List<Kind> kinds = [
      for (final k in spec.kinds.keys)
        if (onlyKinds == null || onlyKinds.contains(k)) k,
    ];
    final corpusProject = Directory('$corpus/$name');
    if (!corpusProject.existsSync()) {
      throw FormatException('no project $name in $corpus');
    }
    if (steps.contains('stock')) {
      _requireStockSdk();
      await buildStock(
        spec: spec,
        corpusProject: corpusProject,
        work: work,
        kinds: kinds,
      );
    }
    if (steps.contains('rules')) {
      await buildRules(
        spec: spec,
        corpusProject: corpusProject,
        overlay: Directory('$overlays/$name'),
        work: work,
        kinds: kinds,
        setup: setup,
      );
    }
  }
  if (!steps.contains('compare')) return 0;

  final List<ByDesignEntry> byDesign = parseByDesign(
    File(flags.value('by-design') ?? '$tool/by_design.json').readAsStringSync(),
  );
  final AndroidTools? tools = AndroidTools.fromEnvironment(
    Platform.environment,
  );
  final used = <ByDesignEntry>{};
  final results = <KindResult>[
    for (final name in names)
      for (final k in projects[name]!.kinds.keys)
        if (onlyKinds == null || onlyKinds.contains(k))
          compareKind(
            work: work,
            project: name,
            kind: k,
            byDesign: byDesign,
            used: used,
            tools: tools,
          ),
  ];
  final List<ByDesignEntry> stale = staleEntries(byDesign, used, results);
  final Map<String, int> overlayLines = {
    for (final n in names) n: countLines(Directory('$overlays/$n')),
  };
  final String text =
      '${textReport(results, stale)}\nOverlay lines (MODULE.bazel, BUILD.bazel, .bazelrc, ...): '
      '${overlayLines.entries.map((e) => '${e.key} ${e.value}').join(', ')}\n';
  stdout.write(text);
  File('$work/report.txt').writeAsStringSync(text);
  writeJson(File('$work/report.json'), {
    ...jsonReport(results),
    'overlay_lines': overlayLines,
    'stale_by_design': [for (final e in stale) e.display],
  });

  final String? ledger = flags.value('ledger');
  if (ledger != null) {
    final String commit = flags.value('commit') ?? _git(root, 'HEAD') ?? '';
    final rows = ledgerRows(
      results,
      date: flags.value('date') ?? _today(),
      commit: commit,
      next: _mergeBase(root),
    );
    final sink = File(ledger).openSync(mode: FileMode.append);
    for (final row in rows) {
      sink.writeStringSync(
        '${jsonEncode({...row, 'overlay_lines': overlayLines[row['project']]})}\n',
      );
    }
    sink.closeSync();
    stdout.writeln('ledger: ${rows.length} rows appended to $ledger');
  }
  return 0;
}

/// Lines in every file of an overlay directory.
int countLines(Directory dir) {
  if (!dir.existsSync()) return 0;
  var n = 0;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File)
      n += const LineSplitter().convert(e.readAsStringSync()).length;
  }
  return n;
}

void _requireStockSdk() {
  if (Platform.environment['FLUTTER_ROOT'] == null) {
    throw const FormatException(
      'the stock side needs the stock SDK: FLUTTER_ROOT is not set '
      '(source the SDK environment first)',
    );
  }
}

String _required(Flags flags, String name) {
  final String? v = flags.value(name);
  if (v == null || v.isEmpty) throw FormatException('--$name is required');
  return v;
}

List<String>? _list(Flags flags, String name) {
  final String? v = flags.value(name);
  if (v == null || v.isEmpty) return null;
  return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

String? _git(String root, String rev) {
  final ProcessResult r = Process.runSync(
    'git',
    ['-C', root, 'rev-parse', '--verify', '--quiet', rev],
    environment: childEnvironment(),
    includeParentEnvironment: false,
  );
  return r.exitCode == 0 ? (r.stdout as String).trim() : null;
}

/// The commit of `next` the rules under test come from: where `HEAD` left
/// it.
String? _mergeBase(String root) {
  final ProcessResult r = Process.runSync(
    'git',
    ['-C', root, 'merge-base', 'HEAD', 'next'],
    environment: childEnvironment(),
    includeParentEnvironment: false,
  );
  return r.exitCode == 0 ? (r.stdout as String).trim() : null;
}

String _today() {
  final DateTime d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
