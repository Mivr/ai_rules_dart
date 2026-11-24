import 'dart:convert';
import 'dart:io';

import 'package:perf/src/bazel.dart';
import 'package:test/test.dart';

void main() {
  test('elapsed time is the last one Bazel printed', () {
    expect(
      elapsedSeconds(
        'INFO: Elapsed time: 2.5s, Critical Path: 1s\nINFO: Elapsed time: 0.815s, Critical Path: 0.1s',
      ),
      0.815,
    );
    expect(elapsedSeconds('nothing'), isNull);
  });

  test('the analyzed counts, with and without aspects', () {
    expect(
      analyzedCounts(
        'INFO: Analyzed 8 targets (0 packages loaded, 12 targets configured).',
      ),
      (targets: 8, configured: 12, aspects: null),
    );
    expect(
      analyzedCounts(
        'INFO: Analyzed 522 targets (0 packages loaded, 5226 targets configured, 2760 aspect applications).',
      ),
      (targets: 522, configured: 5226, aspects: 2760),
    );
    expect(analyzedCounts('INFO: Build completed'), isNull);
  });

  test('actions are counted by mnemonic, cache hits apart', () {
    final log = [
      {
        'mnemonic': 'DartKernel',
        'cacheHit': false,
        'commandArgs': ['a {b} "c"'],
      },
      {'mnemonic': 'DartKernel', 'cacheHit': true},
      {'mnemonic': 'DartKernelLink', 'cacheHit': false},
    ].map((m) => const JsonEncoder.withIndent('  ').convert(m)).join('\n');
    expect(mnemonics(log), {
      'DartKernel': 1,
      'DartKernel (cached)': 1,
      'DartKernelLink': 1,
    });
    expect(mnemonicsOfFile('/nonexistent/exec.json'), isEmpty);
  });

  test('build phases and module extensions from a gzipped profile', () {
    final dir = Directory.systemTemp.createTempSync('profile');
    addTearDown(() => dir.deleteSync(recursive: true));
    final events = [
      {'cat': 'build phase marker', 'name': 'Launch Blaze', 'ts': 0},
      {
        'cat': 'build phase marker',
        'name': 'Load and analyze dependencies',
        'ts': 1000000,
      },
      {'cat': 'build phase marker', 'name': 'Complete build', 'ts': 3500000},
      {
        'name': 'evaluate module extension pub in @@ai_rules_dart+//dart/pub:extensions.bzl%pub',
        'ts': 1000,
        'dur': 250000,
      },
      {'name': 'other', 'ts': 3600000, 'dur': 400000},
    ];
    final f = File('${dir.path}/p.json.gz')
      ..writeAsBytesSync(
        gzip.encode(utf8.encode(jsonEncode({'traceEvents': events}))),
      );
    final read = profileEvents(f.path);
    expect(phaseSeconds(read), {
      'Launch Blaze': 1.0,
      'Load and analyze dependencies': 2.5,
      'Complete build': 0.5,
    });
    expect(extensionSeconds(read, 'extensions.bzl%pub'), 0.25);
  });
}
