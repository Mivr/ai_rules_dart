// Keeps the oversized planner tests and tools under their size ceilings: it
// measures the real sources through runfiles, and checks each measurement on
// synthetic snippets so a regression in a check cannot hide a regression in a
// source.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Blanks comments to spaces and string literals to `x`, keeping line breaks.
String _mask(String source) {
  final token = RegExp(
    <String>[
      r'//[^\n]*',
      r'/\*[\s\S]*?\*/',
      r"r?'''[\s\S]*?'''",
      r'r?"""[\s\S]*?"""',
      r"r'[^'\n]*'",
      r'r"[^"\n]*"',
      r"'(?:\\.|[^'\\\n])*'",
      r'"(?:\\.|[^"\\\n])*"',
    ].join('|'),
  );
  return source.replaceAllMapped(token, (Match m) {
    final fill = m[0]!.startsWith('/') ? ' ' : 'x';
    return m[0]!.replaceAll(RegExp(r'[^\n]'), fill);
  });
}

int _sloc(String masked) =>
    masked.split('\n').where((String l) => l.trim().isNotEmpty).length;

/// The index of the bracket closing the one at [open].
int _matchForward(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if ('([{'.contains(s[i])) depth++;
    if (')]}'.contains(s[i]) && --depth == 0) return i;
  }
  throw StateError('unbalanced bracket at $open');
}

int _matchBack(String s, int close) {
  var depth = 0;
  for (var i = close; i >= 0; i--) {
    if (')]}'.contains(s[i])) depth++;
    if ('([{'.contains(s[i]) && --depth == 0) return i;
  }
  throw StateError('unbalanced bracket at $close');
}

/// Whether the `{` at [open] opens a function body: a `)` precedes it,
/// optionally followed by `async`, `sync` or `*`.
bool _isBodyBrace(String s, int open) =>
    RegExp(r'\)\s*(?:(?:async|sync)\s*\*?\s*)?$')
        .hasMatch(s.substring(0, open));

const Set<String> _controlKeywords = <String>{
  'if', 'for', 'while', 'switch', 'catch', 'when', //
};

/// Each function or closure body as `name` to its SLOC, signature included.
Map<String, int> _functionSlocs(String masked) {
  final sizes = <String, int>{};
  for (var i = 0; i < masked.length; i++) {
    if (masked[i] != '{' || !_isBodyBrace(masked, i)) continue;
    final int paren = _matchBack(masked, masked.lastIndexOf(')', i));
    final String name = RegExp(r'(\w*)\s*$')
        .firstMatch(masked.substring(0, paren))![1]!;
    if (_controlKeywords.contains(name)) continue;
    final int first = masked.lastIndexOf('\n', paren) + 1;
    final String text = masked.substring(first, _matchForward(masked, i) + 1);
    sizes['${name.isEmpty ? '<closure>' : name}@$i'] = _sloc(text);
  }
  return sizes;
}

List<String> _functionsOver(String source, int cap) => <String>[
  for (final MapEntry<String, int> e in _functionSlocs(_mask(source)).entries)
    if (e.value > cap) '${e.key.split('@').first} has ${e.value} SLOC',
];

/// Splits a class body into members: each ends at a `;` or at the `}` of a
/// function body, both outside any bracket.
List<String> _members(String body) {
  final members = <String>[];
  var depth = 0;
  var start = 0;
  var inBody = false;
  for (var i = 0; i < body.length; i++) {
    final String c = body[i];
    if (c == '{' && depth == 0) inBody = _isBodyBrace(body, i);
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if ((c == ';' && depth == 0) || (c == '}' && depth == 0 && inBody)) {
      members.add(body.substring(start, i + 1).trim());
      start = i + 1;
      inBody = false;
    }
  }
  return members;
}

/// Variables a member declares: one per field name, one per method or
/// constructor.
int _variables(String member) {
  final int cut = member.indexOf(RegExp('[(={]'));
  final String head = cut < 0 ? member : member.substring(0, cut);
  if (cut >= 0 && member[cut] == '(') return 1;
  if (RegExp(r'\b(get|set|operator)\b').hasMatch(head)) return 1;
  var names = head;
  while (names.contains(RegExp('<[^<>]*>'))) {
    names = names.replaceAll(RegExp('<[^<>]*>'), '');
  }
  return ','.allMatches(names).length + 1;
}

int _classMembers(String source, String className) {
  final String masked = _mask(source);
  final Match? head = RegExp('class $className\\b[^{]*\\{').firstMatch(masked);
  if (head == null) throw StateError('no class $className');
  final int open = head.end - 1;
  final String body = masked.substring(open + 1, _matchForward(masked, open));
  return _members(body).map(_variables).fold(0, (int a, int b) => a + b);
}

int _count(String source, String call) =>
    RegExp('\\b$call\\(').allMatches(_mask(source)).length;

String _lines(int count, [String line = '  work();']) =>
    List<String>.filled(count, line).join('\n');

String _read(Runfiles runfiles, String arg) =>
    File(runfiles.rlocation(arg)).readAsStringSync();

void main(List<String> args) {
  group('measurements', () {
    test('count code lines, not blank or comment lines', () {
      const src =
          "// c\n\nint a = 1; // t\n/* x\n y */\nvar s = '''\n}\n''';\n";
      expect(_sloc(_mask(src)), 4);
    });

    test('reject a function over the cap and accept one at it', () {
      String fn(int body) => 'void f(int a) {\n${_lines(body)}\n}\n';
      expect(_functionsOver(fn(58), 60), isEmpty);
      expect(_functionsOver(fn(59), 60), ['f has 61 SLOC']);
      expect(
        _functionsOver('void g() {\n  if (a) {\n${_lines(70)}\n  }\n}\n', 60),
        ['g has 74 SLOC'],
      );
    });

    test('count constructors, each field and each method of a class', () {
      String cls(int fields) =>
          'class A {\n  A({required this.a});\n'
          '${List<String>.generate(fields, (int i) => '  final Map<int, int> f$i;').join('\n')}\n'
          '  late final x = <String>{1};\n  int a, b;\n  int get g => 1;\n'
          '  void m() {\n    if (x) {}\n  }\n  bool n() => true;\n}\n';
      expect(_classMembers(cls(0), 'A'), 7);
      expect(_classMembers(cls(33), 'A'), 40);
      expect(_classMembers(cls(34), 'A'), greaterThan(40));
    });

    test('count test and expect calls outside comments and strings', () {
      const src =
          "test('a', () {\n  expect(1, 1); // expect(2)\n"
          "  final s = 'test(';\n});\n";
      expect(_count(src, 'test'), 1);
      expect(_count(src, 'expect'), 1);
    });
  });

  group('sources', () {
    final bool hasArgs = args.length >= 4;
    late Runfiles runfiles;
    setUp(() => runfiles = Runfiles.create());
    final String? skip = hasArgs ? null : 'needs the four source paths';

    test('kernel_module_test.dart keeps its ceiling and its cases', () {
      final String src = _read(runfiles, args[0]);
      expect(_sloc(_mask(src)), lessThanOrEqualTo(7147));
      expect(_count(src, 'test'), greaterThanOrEqualTo(140));
      expect(_count(src, 'expect'), greaterThanOrEqualTo(654));
    }, skip: skip);

    test('the sandbox test holds both relocated cases within its cap', () {
      final String src = _read(runfiles, args[1]);
      expect(_sloc(_mask(src)), lessThanOrEqualTo(400));
      expect(src, contains('produce identical unused inputs in execroot'));
      expect(src, contains('still veto unused inputs under a symlinked'));
      expect(_functionsOver(src, 60), isEmpty);
    }, skip: skip);

    test('kernel_module.dart keeps _UnusedInputs and itself small', () {
      final String src = _read(runfiles, args[2]);
      expect(_classMembers(src, '_UnusedInputs'), lessThanOrEqualTo(40));
      expect(_sloc(_mask(src)), lessThanOrEqualTo(4656));
    }, skip: skip);

    test('analyze_runner_test_support.dart keeps every function small', () {
      final String src = _read(runfiles, args[3]);
      expect(_functionsOver(src, 60), isEmpty);
      expect(_sloc(_mask(src)), lessThanOrEqualTo(600));
    }, skip: skip);
  });
}
