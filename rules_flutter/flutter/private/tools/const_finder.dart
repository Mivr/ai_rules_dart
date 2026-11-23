import 'dart:convert';
import 'dart:io';

/// Parsed CLI arguments record.
typedef ConstFinderArgs = ({
  String outputPath,
  String dartPath,
  String constFinderPath,
  List<String> kernelFiles,
});

/// Parses command-line arguments for the `const_finder` runner tool.
ConstFinderArgs parseConstFinderArgs(List<String> args) {
  String? outputPath;
  String? dartPath;
  String? constFinderPath;
  final kernelFiles = <String>[];

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output':
        if (i + 1 < args.length) outputPath = args[++i];
      case '--dart':
        if (i + 1 < args.length) dartPath = args[++i];
      case '--const-finder':
        if (i + 1 < args.length) constFinderPath = args[++i];
      case '--kernel-file':
        if (i + 1 < args.length) kernelFiles.add(args[++i]);
    }
  }

  if (outputPath == null || dartPath == null || constFinderPath == null) {
    stderr.writeln(
      'Usage: const_finder --output <path> --dart <path> '
      '--const-finder <path> [--kernel-file <path> ...]',
    );
    exit(1);
  }

  return (
    outputPath: outputPath,
    dartPath: dartPath,
    constFinderPath: constFinderPath,
    kernelFiles: kernelFiles,
  );
}

/// Invokes `const_finder.dart.snapshot` via the Dart VM on [kernelFile].
Future<Map<String, dynamic>> runConstFinder(
  String dart,
  String constFinder,
  String kernelFile,
) async {
  final ProcessResult result = await Process.run(dart, [
    constFinder,
    '--kernel-file',
    kernelFile,
    '--class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
    '--class-name',
    'IconData',
    '--annotation-class-name',
    '_StaticIconProvider',
    '--annotation-class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
  ]);

  if (result.exitCode != 0) {
    stderr.writeln('const_finder failed (exit ${result.exitCode}):');
    stderr.writeln(result.stderr);
    exit(1);
  }

  return json.decode(result.stdout as String) as Map<String, dynamic>;
}

/// Merges `const_finder` JSON outputs across one or more compiled kernels into
/// a map from font family key (`family` or `packages/<pkg>/<family>`) to the
/// union of used code points, or returns `null` if any kernel reports
/// non-constant `IconData` locations (disabling icon tree shaking).
Map<String, Set<int>>? mergeConstFinderCodePoints(
  Iterable<Map<String, dynamic>> constFinderOutputs,
) {
  final merged = <String, Set<int>>{};
  for (final output in constFinderOutputs) {
    final List<dynamic> nonConst =
        output['nonConstantLocations'] as List<dynamic>? ?? [];
    if (nonConst.isNotEmpty) {
      stderr.writeln(
        'Warning: ${nonConst.length} non-const IconData instance(s) found. '
        'Icon tree shaking disabled.',
      );
      return null;
    }
    for (final Map<String, dynamic> m
        in (output['constantInstances'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()) {
      final family = m['fontFamily'] as String?;
      final pkg = m['fontPackage'] as String?;
      final dynamic codePointRaw = m['codePoint'];
      final int? codePoint = codePointRaw is num ? codePointRaw.toInt() : null;
      if (family != null && codePoint != null) {
        final String key = (pkg == null || pkg.isEmpty)
            ? family
            : 'packages/$pkg/$family';
        merged.putIfAbsent(key, () => <int>{}).add(codePoint);
      }
    }
  }
  return merged;
}

/// Formats the merged code points as deterministic JSON (sorted keys and code points).
String formatCodePointsJson(Map<String, Set<int>>? merged) {
  if (merged == null) {
    return 'null\n';
  }
  final List<String> sortedKeys = merged.keys.toList()..sort();
  final ordered = <String, List<int>>{
    for (final k in sortedKeys) k: (merged[k]!.toList()..sort()),
  };
  return '${json.encode(ordered)}\n';
}

/// Tool entry point for extracting and saving used icon code points.
Future<void> main(List<String> args) async {
  final ConstFinderArgs parsed = parseConstFinderArgs(args);

  final outputs = <Map<String, dynamic>>[];
  for (final String kernelFile in parsed.kernelFiles) {
    outputs.add(
      await runConstFinder(
        parsed.dartPath,
        parsed.constFinderPath,
        kernelFile,
      ),
    );
  }

  final Map<String, Set<int>>? merged = mergeConstFinderCodePoints(outputs);
  final String content = formatCodePointsJson(merged);
  File(parsed.outputPath).writeAsStringSync(content);
}
