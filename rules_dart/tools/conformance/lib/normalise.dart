/// Everything removed or rewritten before the two sides are compared.
///
/// Each normaliser has a name and a one-line reason, and the comparison counts
/// how often each one changed something, so the report says what was hidden.
/// Anything not covered here is compared as it is.
library;

import 'dart:convert';

import 'package:conformance/layout.dart';

/// A named rewrite applied before comparing.
class Normaliser {
  const Normaliser(this.name, this.kinds, this.reason);

  final String name;
  final Set<Kind> kinds;
  final String reason;
}

const relativePaths = Normaliser(
  'relative-paths',
  {Kind.tests, Kind.analysis},
  'each side builds in its own copy; paths are compared relative to the project root',
);

const hiddenLoadingTests = Normaliser(
  'hidden-loading-tests',
  {Kind.tests},
  'package:test hides its passing "loading <file>" pseudo-tests; the rules\' report never lists them',
);

const testOrder = Normaliser(
  'test-order',
  {Kind.tests, Kind.analysis},
  'cases and diagnostics are compared as sets keyed by file and name; runners order them by scheduling',
);

const repeatedDiagnostics = Normaliser(
  'repeated-diagnostics',
  {Kind.analysis},
  'the rules analyze each target\'s files, so a file two targets list is reported twice; one report per file, line and code',
);

const jsonFormat = Normaliser(
  'json-format',
  {Kind.web, Kind.apk, Kind.linux},
  'JSON files are compared decoded: whitespace and object key order carry no meaning',
);

const serviceWorkerVersion = Normaliser('service-worker-version', {
  Kind.web,
}, 'serviceWorkerVersion is a per-build id that changes on every build');

const lastBuildId = Normaliser(
  'last-build-id',
  {Kind.web},
  '.last_build_id is the stock tool\'s own incremental-build marker, never served',
);

const apkSigning = Normaliser(
  'apk-signing',
  {Kind.apk},
  'signature files (META-INF/*.SF, *.RSA, *.EC, MANIFEST.MF) depend on the signing key, which is per machine',
);

const archiveLayout = Normaliser(
  'archive-layout',
  {Kind.apk},
  'archive entry order, timestamps and compression have no meaning at run time; entries are compared by name and content',
);

const xmlSourceLines = Normaliser(
  'xml-source-lines',
  {Kind.apk},
  'binary XML keeps the line numbers of the merged source manifest, which depend on how it was merged',
);

const xmlRawValues = Normaliser(
  'xml-raw-values',
  {Kind.apk},
  'aapt2 prints each string attribute twice (typed and "Raw"); the typed value is kept',
);

const resourceIds = Normaliser(
  'resource-ids',
  {Kind.apk},
  'aapt2 numbers app resources by the set it links; references are compared by type/name',
);

const attrSymbolOrder = Normaliser(
  'attr-symbol-order',
  {Kind.apk},
  'the enum and flag symbols of an attr resource are looked up by name; their order in the table depends on the linker',
);

const dexClassSet = Normaliser(
  'dex-class-set',
  {Kind.apk},
  'classes are compared as one set across classes*.dex; how they are split over files depends on the dexer',
);

const elfExports = Normaliser(
  'elf-exports',
  {Kind.apk, Kind.linux},
  'native libraries that differ in bytes are compared by exported dynamic symbols (build ids and link order differ)',
);

/// Every normaliser, in the order the report lists them.
const List<Normaliser> allNormalisers = [
  relativePaths,
  hiddenLoadingTests,
  testOrder,
  repeatedDiagnostics,
  jsonFormat,
  serviceWorkerVersion,
  lastBuildId,
  apkSigning,
  archiveLayout,
  xmlSourceLines,
  xmlRawValues,
  resourceIds,
  attrSymbolOrder,
  dexClassSet,
  elfExports,
];

/// Counts how often each normaliser changed something.
class Applied {
  final Map<String, int> counts = {};

  void hit(Normaliser n, [int times = 1]) {
    if (times > 0) counts[n.name] = (counts[n.name] ?? 0) + times;
  }
}

/// [path] relative to the first of [roots] it is under (with or without a
/// `file://` scheme), else unchanged.
String relativeTo(String path, Iterable<String> roots, Applied applied) {
  var p = path.startsWith('file://') ? path.substring('file://'.length) : path;
  for (final root in roots) {
    final prefix = root.endsWith('/') ? root : '$root/';
    if (p.startsWith(prefix)) {
      applied.hit(relativePaths);
      return p.substring(prefix.length);
    }
  }
  return p;
}

/// JSON text decoded and re-encoded compactly with object keys sorted, or
/// null when [text] is not JSON.
String? canonicalJson(String text) {
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException {
    return null;
  }
  return jsonEncode(_sortKeys(value));
}

Object? _sortKeys(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final k in map.keys.toList()..sort()) k: _sortKeys(map[k]),
  },
  final List<Object?> list => [for (final v in list) _sortKeys(v)],
  _ => value,
};

/// [text] with the value of `serviceWorkerVersion` replaced.
String withoutServiceWorkerVersion(String text, Applied applied) {
  final re = RegExp(r'''(serviceWorkerVersion\s*[:=]\s*)(["'])[^"']*\2''');
  if (!re.hasMatch(text)) return text;
  applied.hit(serviceWorkerVersion);
  return text.replaceAllMapped(re, (m) => '${m[1]}"<build>"');
}

/// Whether an APK entry is a signature file.
bool isSigningEntry(String entry) =>
    RegExp(r'^META-INF/[^/]*\.(SF|RSA|DSA|EC)$').hasMatch(entry) ||
    entry == 'META-INF/MANIFEST.MF';
