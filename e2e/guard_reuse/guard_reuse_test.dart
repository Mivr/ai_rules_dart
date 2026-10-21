// Proves an external module can enforce the same directive-URI check as
// rules_dart: this file lives outside rules_dart and reaches the guard only
// through its public library target and stable `package:` URI.
import 'dart:convert';
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

void _check(bool holds, String message) {
  if (!holds) {
    stderr.writeln('guard_reuse_test: $message');
    exit(1);
  }
}

void main() {
  // Single-URI classifiers agree with the shared check.
  _check(
    resolveStagedRelativeTarget('b.dart', '/r/proj/lib/a.dart') ==
        '/r/proj/lib/b.dart',
    'sibling relatives stay inside',
  );
  _check(
    resolveStagedRelativeTarget('../../evil.dart', '/r/proj/lib/a.dart') ==
        '/r/evil.dart',
    'climbs leave the tree instead of clamping',
  );
  _check(
    resolveStagedRelativeTarget('b.dart#frag', '/r/proj/lib/a.dart') == null,
    'fragments name no file',
  );
  _check(
    isEscapingPackageUri('package:p/sub/../../x.dart'),
    'package climbs escape',
  );
  _check(
    isEscapingPackageUri('package:p//x.dart'),
    'package empty segments escape',
  );
  _check(
    !isEscapingPackageUri('package:p/a.dart'),
    'URIs inside the package do not escape',
  );
  _check(hasEmptyPathSegment('a//b.dart'), 'doubled slashes count');
  _check(!hasEmptyPathSegment('a/b.dart'), 'single slashes do not');
  _check(
    isDisallowedDirectiveUri('file:///etc/hosts'),
    'file: URIs are disallowed',
  );
  _check(
    isDisallowedDirectiveUri('//host/evil.dart'),
    '//-authority is refused',
  );
  _check(
    isDisallowedDirectiveUri('\\\\host\\evil.dart'),
    'backslash-spelled authority is refused',
  );
  _check(!isDisallowedDirectiveUri('b.dart'), 'a relative path is allowed');
  _check(
    !isDisallowedDirectiveUri('package:p/a.dart'),
    'package: URIs are allowed',
  );
  _check(
    resolveDirectiveUri('package:p/a.dart', 'pkg/lib/m.dart', {
          'p': 'pkg/lib',
        }) ==
        'pkg/lib/a.dart',
    'package: URIs resolve through the package map',
  );

  // The staged-tree check refuses every escape and allows the declared tree,
  // with the same diagnostics rules_dart's own runners print.
  final tmp = Directory.systemTemp.createTempSync('guard_reuse_');
  try {
    final staged = Directory('${tmp.path}/pkg/demo.proj')
      ..createSync(recursive: true);
    void stagedFile(String relative, String content) {
      File('${staged.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    stagedFile('lib/a.dart', "import 'b.dart';\n");
    stagedFile('lib/b.dart', 'library b;\n');
    stagedFile('lib/climb.dart', "import '../../evil.dart';\n");
    stagedFile('lib/scheme.dart', "import 'file:///etc/hosts';\n");
    stagedFile('lib/pkg.dart', "import 'package:demo/sub/../../evil.dart';\n");
    stagedFile('lib/empty.dart', "import 'a//b.dart';\n");
    stagedFile('lib/slashauth.dart', "import '//host/evil.dart';\n");
    stagedFile('lib/frag.dart', "import 'b.dart#frag';\n");
    File('${staged.path}/lib/backslash.dart')
      ..createSync(recursive: true)
      ..writeAsBytesSync(utf8.encode("import '\\\\\\\\host\\\\evil.dart';\n"));
    File('${staged.path}/lib/malformed.dart')
      ..createSync(recursive: true)
      ..writeAsBytesSync([
        ...utf8.encode("import 'b.dart';\n// "),
        0xff,
        ...utf8.encode("\nimport '../../evil.dart';\n"),
      ]);

    final violations = findStagedDirectiveViolations([
      staged.path,
    ], tool: 'guard-reuse');
    String at(String relative) =>
        '${staged.path}/$relative'.replaceAll(r'\', '/');
    final expected = [
      "guard-reuse: ${at('lib/backslash.dart')} import '\\\\host\\evil.dart' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/climb.dart')} import '../../evil.dart' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/empty.dart')} import 'a//b.dart' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/frag.dart')} import 'b.dart#frag' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/malformed.dart')} import '../../evil.dart' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/pkg.dart')} import "
          "'package:demo/sub/../../evil.dart' is not a declared input.",
      "guard-reuse: ${at('lib/scheme.dart')} import 'file:///etc/hosts' "
          'is not a declared input.',
      "guard-reuse: ${at('lib/slashauth.dart')} import '//host/evil.dart' "
          'is not a declared input.',
    ];
    _check(
      violations.length == expected.length,
      'expected ${expected.length} violations, got ${violations.length}: '
      '$violations',
    );
    for (var i = 0; i < expected.length; i++) {
      _check(
        violations[i] == expected[i],
        'violation $i mismatch:\n  got:      ${violations[i]}\n'
        '  expected: ${expected[i]}',
      );
    }

    _check(
      findStagedDirectiveViolations([
        '${tmp.path}/no-such-dir',
      ], tool: 'guard-reuse').isEmpty,
      'missing roots scan as empty',
    );
  } finally {
    tmp.deleteSync(recursive: true);
  }

  stdout.writeln('guard_reuse_test: external guard reuse matches rules_dart');
}
