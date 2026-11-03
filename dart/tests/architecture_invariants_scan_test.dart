import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Source half of `//dart/tests:architecture_invariants_test`: the provider
/// invariants of `docs/ARCHITECTURE.md` that live in `.bzl` source rather
/// than in an analyzed target.
///
/// - `DartInfo` declares no field whose name contains `flutter`, `android`,
///   `ios` or `apple`: it carries zero Flutter concepts, and a rule set built
///   on rules_dart wraps it instead of extending it.
/// - No production `.bzl` outside `dart/private/dart_info.bzl` constructs
///   `DartInfo(` by hand, directly or through a load alias or re-binding: it
///   is built through `dart_info()`, `dart_info_no_package()` and
///   `dart_info_multi()`.
/// - Every label-typed `deps` attribute a production `.bzl` declares
///   requires `providers = [DartInfo]`.
///
/// Production means every `.bzl` in the workspace outside `e2e/` and outside
/// any `tests` or `testdata` directory: fixtures there hand-build `DartInfo`
/// on purpose. The test walks the live tree from the workspace root, so a new
/// file is checked without re-listing anything, and reports one `file:line`
/// finding per violation. It runs unsandboxed and local, so it always re-runs.
/// The root comes from a runfiles anchor, this test's own source passed as an
/// `rlocationpath` argument, so it resolves where runfiles are a manifest
/// (Windows) as well as where they are links.
void main(List<String> args) {
  group('architecture invariants in the live tree', () => _liveTree(args));
  group('provider field scanner', _fieldScannerUnits);
  group('constructor call scanner', _constructorScannerUnits);
  group('deps and tree scanner', _depsScannerUnits);
}

/// The one file allowed to call the `DartInfo` constructor.
const _constructorFile = 'dart/private/dart_info.bzl';

/// The canonical `DartInfo` constructors `_constructorFile` must define.
const _constructors = ['dart_info', 'dart_info_no_package', 'dart_info_multi'];

/// Substrings no `DartInfo` field name may contain, compared lower-cased.
const _platformWords = ['flutter', 'android', 'ios', 'apple'];

/// Directory names whose `.bzl` files are test sources, not production.
const _testDirs = {'tests', 'testdata'};

/// The invariants checked against every production `.bzl` in the live tree.
void _liveTree(List<String> args) {
  late final List<_Source> production;

  setUpAll(() => production = _productionBzl(_workspaceRoot(args)));

  test('production .bzl files are discovered', () {
    final List<String> paths = production.map((s) => s.path).toList();
    expect(
      paths,
      containsAll(['dart/providers.bzl', _constructorFile, 'dart/defs.bzl']),
      reason:
          'the walk missed core rule files; every check would pass vacuously',
    );
    expect(paths.where((p) => !_isProduction(p)), isEmpty);
  });

  test('DartInfo declares no platform field', () {
    final List<_FieldScan> scans = production
        .map(_scanProviderFields)
        .nonNulls
        .toList();
    expect(
      scans,
      hasLength(1),
      reason: 'expected exactly one `DartInfo = provider(` in production .bzl',
    );
    expect(
      scans.single.fields,
      containsAll(['package_name', 'transitive_srcs', 'transitive_packages']),
      reason: 'the DartInfo field list was not read; the check would pass vacuously',
    );
    _expectNoFindings(scans.single.findings);
  });

  test('DartInfo is constructed only by the canonical constructors', () {
    final findings = <String>[];
    for (final source in production) {
      if (source.path != _constructorFile) {
        findings.addAll(_dartInfoCalls(source));
      }
    }
    _expectNoFindings(findings);
  });

  test('$_constructorFile defines the constructors and builds DartInfo', () {
    final _Source source = production.singleWhere(
      (s) => s.path == _constructorFile,
    );
    for (final String name in _constructors) {
      expect(
        RegExp(
          '^def ${RegExp.escape(name)}\\(',
          multiLine: true,
        ).hasMatch(source.code),
        isTrue,
        reason: '$_constructorFile must define $name()',
      );
    }
    expect(_dartInfoCalls(source), isNotEmpty);
  });

  test('every label deps attribute requires providers = [DartInfo]', () {
    final List<_DepsScan> scans = production.map(_scanDepsAttrs).toList();
    expect(
      scans.fold(0, (sum, scan) => sum + scan.declared),
      greaterThan(5),
      reason:
          "expected the rules' deps attributes; the check would pass vacuously",
    );
    _expectNoFindings([for (final scan in scans) ...scan.findings]);
  });
}

/// Fails with one finding per line when [findings] is not empty.
void _expectNoFindings(List<String> findings) =>
    expect(findings, isEmpty, reason: '\n${findings.join('\n')}');

/// Pins the `DartInfo` field scanner against inline sources.
void _fieldScannerUnits() {
  test('a platform field is reported with file:line, case-insensitively', () {
    final _FieldScan scan = _scanProviderFields(
      _Source(
        'probe.bzl',
        'DartInfo = provider(\n'
            '    doc = "a doc naming flutter_assets: is not a field",\n'
            '    fields = {\n'
            '        "package_name": "str: {nested: [1]}",\n'
            '        "iOS_bundle": "str: flagged",\n'
            '    },\n'
            ')\n',
      ),
    )!;
    expect(scan.fields, ['package_name', 'iOS_bundle']);
    expect(scan.findings, hasLength(1));
    expect(
      scan.findings.single,
      startsWith('probe.bzl:5: DartInfo field "iOS_bundle"'),
    );
  });

  test('a list of fields is read too, and other providers are not', () {
    final _FieldScan scan = _scanProviderFields(
      _Source(
        'probe.bzl',
        'FlutterInfo = provider(fields = {"flutter_root": ""})\n'
            'DartInfo = provider(fields = ["lib_root", "android_abi"])\n',
      ),
    )!;
    expect(scan.fields, ['lib_root', 'android_abi']);
    expect(scan.findings, hasLength(1));
    expect(scan.findings.single, startsWith('probe.bzl:2:'));
    expect(
      _scanProviderFields(_Source('probe.bzl', 'X = provider()\n')),
      isNull,
    );
  });
}

/// Pins the hand-built `DartInfo(` scanner against inline sources.
void _constructorScannerUnits() {
  test('a direct construction is reported; mentions in comments and strings are not', () {
    final List<String> findings = _dartInfoCalls(
      _Source(
        'probe.bzl',
        '# never call DartInfo(...) here\n'
            'DOC = "DartInfo(transitive_srcs)"\n'
            'info = DartInfo(\n'
            '    transitive_srcs = depset(),\n'
            ')\n',
      ),
    );
    expect(findings, hasLength(1));
    expect(
      findings.single,
      startsWith('probe.bzl:3: DartInfo constructed by hand;'),
    );
  });

  test('a construction through a load alias or a re-binding is reported', () {
    final List<String> findings = _dartInfoCalls(
      _Source(
        'probe.bzl',
        'load("//dart:providers.bzl", _Info = "DartInfo")\n'
            '_mid = _Info\n'
            '_leaf = _mid\n'
            'a = _Info(transitive_srcs = depset())\n'
            'b = _leaf()\n'
            'c = dart_info(label = "x")\n',
      ),
    );
    expect(findings, hasLength(2));
    expect(
      findings,
      contains(
        startsWith("probe.bzl:4: DartInfo constructed by hand through '_Info'"),
      ),
    );
    expect(
      findings,
      contains(
        startsWith("probe.bzl:5: DartInfo constructed by hand through '_leaf'"),
      ),
    );
  });
}

/// Pins the `deps` scanner, the production filter and the blanking.
void _depsScannerUnits() {
  test('a label deps attribute without providers = [DartInfo] is reported', () {
    final _DepsScan scan = _scanDepsAttrs(
      _Source(
        'probe.bzl',
        'load("//dart:providers.bzl", _Info = "DartInfo")\n'
            'A = {"deps": attr.label_list(doc = "providers = [DartInfo]")}\n'
            'B = {"deps": attr.label_list(providers = [DartInfo])}\n'
            'C = {"deps": attr.label_list(providers = [OtherInfo])}\n'
            'D = dict(deps = attr.label(providers = [_Info]))\n'
            'E = {"deps": attr.string_list()}\n'
            '# F = {"deps": attr.label_list()}\n',
      ),
    );
    expect(scan.declared, 4);
    expect(scan.findings, hasLength(2));
    expect(
      scan.findings[0],
      startsWith('probe.bzl:2: deps attribute without providers = [DartInfo]'),
    );
    expect(
      scan.findings[1],
      startsWith('probe.bzl:4: deps attribute without providers = [DartInfo]'),
    );
  });

  test('test sources are not production', () {
    expect(_isProduction('dart/private/dart_test.bzl'), isTrue);
    expect(_isProduction('dart/ext/drift/defs.bzl'), isTrue);
    expect(_isProduction('dart/tests/no_lv_fixture/no_lv_rules.bzl'), isFalse);
    expect(_isProduction('dev/testdata/rules.bzl'), isFalse);
    expect(_isProduction('e2e/link_hook/in_rule.bzl'), isFalse);
    expect(_isProduction('.github/x.bzl'), isFalse);
  });

  test('blanking keeps every offset and line', () {
    const text = 'a = "x#y" # DartInfo(\nb = """\nDartInfo(\n""" + \'q\'\n';
    final String code = _blank(text);
    expect(code.length, text.length);
    expect(code.split('\n'), hasLength(text.split('\n').length));
    expect(code, isNot(contains('DartInfo')));
    expect(code, startsWith('a = '));
  });
}

/// One `.bzl` file: its workspace-relative path, its text, and the same text
/// with every string literal and comment blanked, so offsets and line
/// numbers match between the two.
class _Source {
  new(this.path, this.text) : code = _blank(text);

  final String path;
  final String text;
  final String code;

  /// The 1-based line holding [offset].
  int lineAt(int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;

  /// `path:line` of [offset], as findings report it.
  String at(int offset) => '$path:${lineAt(offset)}';
}

/// A string literal (triple-quoted ones span lines) or a `#` comment.
final _literalOrComment = RegExp(
  r'[rR]?(?:"""[\s\S]*?"""'
  r"|'''[\s\S]*?'''"
  r'|"(?:\\.|[^"\\\n])*"'
  r"|'(?:\\.|[^'\\\n])*')"
  r'|#[^\n]*',
);

/// [text] with every string literal and comment replaced by spaces, newlines
/// kept.
String _blank(String text) => text.replaceAllMapped(
  _literalOrComment,
  (m) => m[0]!.replaceAll(RegExp(r'[^\n]'), ' '),
);

/// The bracket depth change one character makes.
int _bracketDelta(int unit) => switch (String.fromCharCode(unit)) {
  '(' || '[' || '{' => 1,
  ')' || ']' || '}' => -1,
  _ => 0,
};

/// The net bracket depth change across blanked [code].
int _nesting(String code) =>
    code.codeUnits.fold(0, (depth, unit) => depth + _bracketDelta(unit));

/// The offset of the bracket closing the one at [open] in blanked [code], or
/// the end of [code] when it never closes.
int _closing(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    depth += _bracketDelta(code.codeUnitAt(i));
    if (depth == 0) return i;
  }
  return code.length;
}

/// The field names of a `DartInfo = provider(...)` definition and the
/// findings for those naming a platform.
class _FieldScan {
  final fields = <String>[];
  final findings = <String>[];
}

/// Scans the `DartInfo` definition in [source], or returns null when it
/// defines none. `fields` may be a dict (its keys are the names) or a list.
_FieldScan? _scanProviderFields(_Source source) {
  final String code = source.code;
  final RegExpMatch? definition = RegExp(r'\bDartInfo\s*=\s*provider\s*\(')
      .firstMatch(code);
  if (definition == null) return null;
  final int end = _closing(code, definition.end - 1);
  final RegExpMatch? fields = RegExp(r'\bfields\s*=\s*([\[{])')
      .firstMatch(code.substring(0, end).substring(definition.end));
  final scan = _FieldScan();
  if (fields == null) return scan;
  final int open = definition.end + fields.end - 1;
  final int close = _closing(code, open);
  var depth = 0;
  int position = open + 1;
  for (final RegExpMatch literal in _literalOrComment.allMatches(
    source.text,
    open + 1,
  )) {
    if (literal.start >= close) break;
    depth += _nesting(code.substring(position, literal.start));
    position = literal.end;
    final String token = literal[0]!;
    final bool isKey =
        code[open] == '[' ||
        RegExp(r'\s*:').matchAsPrefix(code, literal.end) != null;
    if (depth != 0 || token.startsWith('#') || !isKey) continue;
    _addField(
      scan,
      source,
      literal.start,
      token.replaceAll(RegExp('^[rR]?["\']+|["\']+\$'), ''),
    );
  }
  return scan;
}

/// Records [name] as a `DartInfo` field, and reports it when it names a
/// platform.
void _addField(_FieldScan scan, _Source source, int offset, String name) {
  scan.fields.add(name);
  final String? word = _platformWords
      .where(name.toLowerCase().contains)
      .firstOrNull;
  if (word == null) return;
  scan.findings.add(
    '${source.at(offset)}: DartInfo field "$name" names a platform ("$word"); '
    'DartInfo carries zero Flutter concepts, so platform state belongs in a '
    'provider of the rule set that needs it',
  );
}

/// The local names that call the `DartInfo` constructor in [source]:
/// `DartInfo` itself, every load alias bound to it, and plain re-bindings of
/// those (`_b = _a`), closed to a fixpoint.
Set<String> _dartInfoNames(_Source source) {
  final names = {'DartInfo'};
  for (final RegExpMatch load in RegExp(
    r'\bload\s*\(',
  ).allMatches(source.code)) {
    final String body = source.text.substring(
      load.end,
      _closing(source.code, load.end - 1),
    );
    for (final RegExpMatch alias in RegExp(
      '([A-Za-z_]\\w*)\\s*=\\s*["\']DartInfo["\']',
    ).allMatches(body)) {
      names.add(alias[1]!);
    }
  }
  final List<RegExpMatch> bindings = RegExp(
    r'^\s*([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*$',
    multiLine: true,
  ).allMatches(source.code).toList();
  var grew = true;
  while (grew) {
    grew = false;
    for (final binding in bindings) {
      if (names.contains(binding[2]) && names.add(binding[1]!)) grew = true;
    }
  }
  return names;
}

/// One `file:line` finding per `DartInfo` constructor call in [source].
List<String> _dartInfoCalls(_Source source) {
  final findings = <String>[];
  for (final String name in _dartInfoNames(source)) {
    final through = name == 'DartInfo' ? '' : " through '$name'";
    for (final RegExpMatch call in RegExp(
      '\\b${RegExp.escape(name)}\\s*\\(',
    ).allMatches(source.code)) {
      findings.add(
        '${source.at(call.start)}: DartInfo constructed by hand$through; build '
        'it through ${_constructors.map((c) => '$c()').join(', ')}',
      );
    }
  }
  return findings;
}

/// The label-typed `deps` attributes one file declares and the findings for
/// those not requiring `DartInfo`.
class _DepsScan {
  int declared = 0;
  final findings = <String>[];
}

/// A `deps` attribute declared with a label-typed `attr` constructor, as a
/// dict entry (`"deps": attr.label_list(`) or a keyword (`deps = attr.label(`).
final _depsAttr = RegExp(
  '(?:["\']deps["\']\\s*:|\\bdeps\\s*=)\\s*attr\\.'
  r'(?:label|label_list|label_keyed_string_dict|string_keyed_label_dict)\s*\(',
);

/// Scans every label-typed `deps` attribute [source] declares.
_DepsScan _scanDepsAttrs(_Source source) {
  final scan = _DepsScan();
  final String names = _dartInfoNames(source).map(RegExp.escape).join('|');
  final requiresDartInfo = RegExp('\\b(?:$names)\\b');
  for (final RegExpMatch attr in _depsAttr.allMatches(source.text)) {
    final int open = attr.end - 1;
    if (source.code[open] != '(') continue; // In a comment or a string.
    scan.declared++;
    final String call = source.code.substring(
      open,
      _closing(source.code, open),
    );
    final RegExpMatch? providers = RegExp(r'\bproviders\s*=\s*\[')
        .firstMatch(call);
    final String list = providers == null
        ? ''
        : call.substring(providers.end - 1, _closing(call, providers.end - 1));
    if (!requiresDartInfo.hasMatch(list)) {
      scan.findings.add(
        '${source.at(attr.start)}: deps attribute without providers = '
        '[DartInfo]; every deps gates on DartInfo, which is what decides that '
        'a target can be depended on',
      );
    }
  }
  return scan;
}

/// Whether the workspace-relative [path] is a production `.bzl`: outside
/// `e2e/`, `tests`/`testdata` directories, hidden directories and Bazel's
/// convenience links.
bool _isProduction(String path) {
  final List<String> dirs = path.split('/')..removeLast();
  if (dirs.isNotEmpty && dirs.first == 'e2e') return false;
  return !dirs.any(
    (d) => d.startsWith('.') || d.startsWith('bazel-') || _testDirs.contains(d),
  );
}

/// Every production `.bzl` under [root], sorted by path. Links are not
/// followed, so Bazel's output trees are never entered.
List<_Source> _productionBzl(String root) {
  final sources = <_Source>[];
  for (final FileSystemEntity entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.bzl')) continue;
    final String path = entity.path
        .substring(root.length + 1)
        .replaceAll(r'\', '/');
    if (_isProduction(path)) {
      sources.add(_Source(path, entity.readAsStringSync()));
    }
  }
  sources.sort((a, b) => a.path.compareTo(b.path));
  return sources;
}

/// The source-tree workspace root: the nearest ancestor of the resolved
/// anchor (or, for a direct `dart test` run with no argument, of the current
/// directory) holding both `MODULE.bazel` and `dart/providers.bzl`. Resolving
/// the anchor's links lands in the source tree rather than in a runfiles or
/// execroot mirror.
String _workspaceRoot(List<String> args) {
  final File? anchor = args.isEmpty
      ? null
      : File(Runfiles.create().rlocation(args.first));
  final String start = anchor != null && anchor.existsSync()
      ? anchor.resolveSymbolicLinksSync()
      : Directory.current.resolveSymbolicLinksSync();
  for (
    var dir = Directory(start);
    dir.parent.path != dir.path;
    dir = dir.parent
  ) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        File('${dir.path}/dart/providers.bzl').existsSync()) {
      return dir.path;
    }
  }
  fail(
    'cannot locate the workspace root above $start. The test must run '
    'unsandboxed (tags = ["no-sandbox"]) with its own source as the '
    'rlocationpath anchor argument, so it reads the live tree.',
  );
}
