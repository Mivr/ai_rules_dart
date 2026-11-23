/// `file-length`: production source files over 800 lines. Reported, never a
/// failure.
library;

import 'package:inventory/source_tree.dart';

/// The longest a production source file should be.
const int maxFileLines = 800;

/// A production file over [maxFileLines] lines.
typedef LongFile = ({String path, int lines});

/// The production files of [tree] longer than [maxFileLines], longest first.
List<LongFile> longFiles(
  SourceTree tree,
  bool Function(String path) isProductionSource,
) {
  final long = <LongFile>[
    for (final String path in tree.paths)
      if (isProductionSource(path))
        if (countLines(tree.read(path)) case final int lines
            when lines > maxFileLines)
          (path: path, lines: lines),
  ];
  return long..sort((a, b) => b.lines.compareTo(a.lines));
}
