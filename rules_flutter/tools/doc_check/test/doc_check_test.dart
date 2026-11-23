/// Tests for the Starlark documentation checker: one fixture per rule that
/// breaks only that rule, the lists, the listings and the wire codec.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../doc_check.dart';
import '../failure.dart';
import '../policy.dart';
import '../rules.dart';
import '../source_probe.dart';
import '../stardoc.dart';
import '../wire.dart';
import 'fixtures.dart';
import 'proto_writer.dart';

/// The rules broken (not merely warned about) by [bytes].
Set<String> broken(
  Uint8List bytes, {
  bool returns = false,
  Set<String> shared = const {},
}) {
  final checker = DocChecker(
    returnsValue: (file, name) => returns,
    sharedPhrasings: shared,
  );
  final CheckReport report = checker.check([ModuleDoc.parse(bytes)]);
  return {
    for (final v in report.findings)
      if (!v.warning) v.rule,
  };
}

/// The advisory rules raised by [bytes].
Set<String> warned(Uint8List bytes) {
  final checker = DocChecker(returnsValue: (file, name) => false);
  final CheckReport report = checker.check([ModuleDoc.parse(bytes)]);
  return {
    for (final v in report.findings)
      if (v.warning) v.rule,
  };
}

/// A well-documented module holding one of everything.
Uint8List clean() => module(
  rules: [
    rule('r', attrs: [attr('a', doc: 'The default is "x" for sources.')]),
  ],
  macros: [macro('m')],
  aspects: [aspect('asp')],
  repoRules: [repoRule('repo')],
  extensions: [
    extension('ext', tags: [tagClass('tag')]),
  ],
  funcs: [
    func('f', params: [param('p')], returns: 'The computed value.'),
  ],
  providers: [
    provider('P', fields: [('x', goodDoc)]),
  ],
);

void main() {
  group('a documented module', () {
    test('passes every rule', () {
      expect(broken(clean(), returns: true), isEmpty);
    });
  });

  group('module docstring', () {
    test('missing fails', () {
      expect(broken(module(doc: '')), {'module-docstring-missing'});
    });
    test('present passes', () => expect(broken(module()), isEmpty));
  });

  group('symbol docs', () {
    final cases = <String, Uint8List Function(String doc)>{
      'rule': (d) => module(rules: [rule('r', doc: d)]),
      'macro': (d) => module(macros: [macro('m', doc: d)]),
      'aspect': (d) => module(aspects: [aspect('asp', doc: d)]),
      'repository rule': (d) => module(repoRules: [repoRule('repo', doc: d)]),
      'module extension': (d) => module(extensions: [extension('ext', doc: d)]),
      'tag class': (d) => module(
        extensions: [
          extension('ext', tags: [tagClass('tag', doc: d)]),
        ],
      ),
      'function': (d) => module(funcs: [func('f', doc: d)]),
      'provider': (d) => module(providers: [provider('P', doc: d)]),
    };
    cases.forEach((kind, build) {
      test('$kind without a doc fails', () {
        expect(broken(build('')), {'symbol-doc-missing'});
      });
      test('$kind with a doc passes', () {
        expect(broken(build(goodDoc)), isEmpty);
      });
    });
  });

  group('attribute docs', () {
    Uint8List withAttr(ProtoWriter a) => module(
      rules: [
        rule('r', attrs: [a]),
      ],
    );
    test('an undocumented attribute fails', () {
      expect(broken(withAttr(attr('srcs', doc: ''))), {'attr-doc-missing'});
    });
    test('a documented attribute passes', () {
      expect(broken(withAttr(attr('srcs'))), isEmpty);
    });
    test('a natively defined attribute needs no doc', () {
      expect(broken(withAttr(attr('name', doc: '', native: true))), isEmpty);
    });
    test('a tag class attribute is checked too', () {
      final Uint8List bytes = module(
        extensions: [
          extension(
            'ext',
            tags: [
              tagClass('tag', attrs: [attr('v', doc: '')]),
            ],
          ),
        ],
      );
      expect(broken(bytes), {'attr-doc-missing'});
    });
  });

  group('provider docs', () {
    Uint8List withFields(List<(String, String)> fields) => module(
      providers: [provider('P', fields: fields)],
    );
    test('a field without a doc fails', () {
      expect(broken(withFields([('x', '')])), {'provider-field-doc-missing'});
    });
    test('a list-style field (name only) fails', () {
      expect(broken(withFields([('x', ''), ('y', '')])), {
        'provider-field-doc-missing',
      });
    });
    test('documented fields pass', () {
      expect(broken(withFields([('x', goodDoc)])), isEmpty);
    });
  });

  group('function docs', () {
    Uint8List withParam(ProtoWriter p, {String returns = ''}) => module(
      funcs: [
        func('f', params: [p], returns: returns),
      ],
    );
    test('an undocumented parameter fails', () {
      expect(broken(withParam(param('p', doc: ''))), {'param-doc-missing'});
    });
    test('an undocumented *args fails', () {
      expect(broken(withParam(param('args', doc: '', role: 4))), {
        'param-doc-missing',
      });
    });
    test('an undocumented **kwargs fails', () {
      expect(broken(withParam(param('kwargs', doc: '', role: 5))), {
        'param-doc-missing',
      });
    });
    test('documented parameters pass', () {
      expect(broken(withParam(param('p'))), isEmpty);
    });
    test('a value-returning function without Returns fails', () {
      expect(broken(withParam(param('p')), returns: true), {
        'returns-missing',
      });
    });
    test('a value-returning function with Returns passes', () {
      final Uint8List bytes = withParam(
        param('p'),
        returns: 'The value computed.',
      );
      expect(broken(bytes, returns: true), isEmpty);
    });
    test('a filler Returns section fails', () {
      final Uint8List bytes = withParam(param('p'), returns: 'A value.');
      expect(broken(bytes, returns: true), {'doc-too-short'});
    });
    test('a function that returns nothing needs no Returns', () {
      expect(broken(withParam(param('p'))), isEmpty);
    });
  });

  group('doc quality', () {
    Uint8List attrWith(String doc) => module(
      rules: [
        rule('r', attrs: [attr('srcs', doc: doc)]),
      ],
    );
    test('under 3 words fails', () {
      expect(broken(attrWith('Source files.')), {'doc-too-short'});
    });
    test('under 15 characters fails', () {
      expect(broken(attrWith('a b c d')), {'doc-too-short'});
    });
    test('a restated name fails', () {
      expect(broken(attrWith('The srcs attribute.')), {'doc-restates-name'});
    });
    test('a longer restatement of the name fails', () {
      final Uint8List bytes = module(
        rules: [
          rule(
            'r',
            attrs: [attr('output_dir', doc: 'the Output Dir attribute')],
          ),
        ],
      );
      expect(broken(bytes), {'doc-restates-name'});
    });
    for (final marker in ['TODO', 'TBD', 'FIXME', 'XXX', 'See above']) {
      test('$marker fails', () {
        expect(broken(attrWith('Source files for the app, $marker.')), {
          'doc-placeholder',
        });
      });
    }
    test('a substantive doc passes', () {
      expect(
        broken(attrWith('Dart sources compiled into the kernel.')),
        isEmpty,
      );
    });
  });

  group('shared attribute docs', () {
    const shared = 'The label of the Dart SDK toolchain used.';
    Uint8List sharing(int count) => module(
      rules: [
        for (var i = 0; i < count; i++)
          rule('r$i', attrs: [attr('sdk', doc: shared)]),
      ],
    );
    test('3 attributes with one doc pass', () {
      expect(broken(sharing(3)), isEmpty);
    });
    test('4 attributes with one doc fail', () {
      expect(broken(sharing(4)), {'doc-duplicate'});
    });
    test("Bazel's generated doc for an implicit name is never a duplicate", () {
      final Uint8List bytes = module(
        rules: [
          for (var i = 0; i < 5; i++)
            rule('r$i', attrs: [attr('name', doc: shared, type: 1)]),
        ],
      );
      expect(broken(bytes), isEmpty);
    });
    test('an approved phrasing passes', () {
      expect(broken(sharing(4), shared: {shared}), isEmpty);
    });
  });

  group('default warning', () {
    Uint8List withDoc(String doc, {bool mandatory = false}) => module(
      rules: [
        rule(
          'r',
          attrs: [attr('mode', doc: doc, mandatory: mandatory)],
        ),
      ],
    );
    test('an optional attribute that omits its default warns', () {
      final Uint8List bytes = withDoc('Selects the build mode for the output.');
      expect(warned(bytes), {'attr-default-undocumented'});
      expect(broken(bytes), isEmpty);
    });
    test('naming the default clears it', () {
      expect(warned(withDoc('Build mode; the default is release.')), isEmpty);
    });
    test('a mandatory attribute never warns', () {
      final Uint8List bytes = withDoc(
        'Selects the build mode.',
        mandatory: true,
      );
      expect(warned(bytes), isEmpty);
    });
  });

  group('allowlist', () {
    final findings = [
      const Violation(
        file: '//pkg:lib.bzl',
        symbol: 'r.srcs',
        rule: 'doc-too-short',
      ),
    ];
    test('an entry covering a violation lets it through', () {
      final list = Entries.parse(
        'r.srcs legacy rule',
        'list',
        splitAllowlistLine,
      );
      expect(judge(findings, list, []).ok, isTrue);
    });
    test('an entry that covers nothing fails', () {
      final list = Entries.parse('gone.attr old', 'list', splitAllowlistLine);
      final Verdict verdict = judge([], list, []);
      expect(verdict.ok, isFalse);
      expect(verdict.errors.single, contains('gone.attr'));
    });
    test('an entry with no reason fails', () {
      final list = Entries.parse('r.srcs', 'list', splitAllowlistLine);
      expect(list.problems.single, contains('no reason'));
    });
    test('a warning is never fatal', () {
      const warning = Violation(
        file: 'f',
        symbol: 's',
        rule: 'w',
        warning: true,
      );
      final Verdict verdict = judge([warning], Entries.empty, []);
      expect(verdict.ok, isTrue);
      expect(verdict.warnings, ['warning: f:s: w']);
    });
    test('the violation line is file:symbol: rule', () {
      expect(judge(findings, Entries.empty, []).errors, [
        '//pkg:lib.bzl:r.srcs: doc-too-short',
      ]);
    });
    test('an approved phrasing nobody needs fails', () {
      final list = Entries.parse('Used on few. | why', 'p', splitPhrasingLine);
      expect(staleShared(list, {'Used on few.': 3}), isNotEmpty);
      expect(staleShared(list, {'Used on few.': 4}), isEmpty);
    });
  });

  group('checked-in lists', () {
    String read(String key) {
      final String? rlocation = Platform.environment[key];
      if (rlocation == null || rlocation.isEmpty) {
        throw StateError('$key is not set; the test needs the list in `data`');
      }
      return File(Runfiles.create().rlocation(rlocation)).readAsStringSync();
    }

    test('the allowlist is well formed and starts empty', () {
      final list = Entries.parse(
        read('DOC_CHECK_ALLOWLIST_RLOCATION'),
        'allowlist.txt',
        splitAllowlistLine,
      );
      expect(list.problems, isEmpty);
      // The allowlist may only shrink: raise this and the review rejects it.
      const ceiling = 0;
      expect(list.reasons.length, lessThanOrEqualTo(ceiling));
    });

    test('the shared phrasings are well formed', () {
      final list = Entries.parse(
        read('DOC_CHECK_SHARED_RLOCATION'),
        'shared_phrasings.txt',
        splitPhrasingLine,
      );
      expect(list.problems, isEmpty);
    });
  });

  group('source probe', () {
    test('finds value-returning functions only', () {
      const source = '''
def a(x):
    """Doc.

    return not counted
    """
    return x

def b(x):
    def inner():
        return 1
    inner()

def c(x):
    return

def d(x):
    return None

def e(x):
    if x:
        return [
            x,
        ]
    return struct(a = 1)
''';
      expect(valueReturningFunctions(source), {'a', 'e'});
    });
    test('a missing source fails and names the file', () {
      final probe = SourceReturns(Directory.systemTemp.path);
      expect(
        () => probe.call('//no/such:file.bzl', 'f'),
        throwsA(
          isA<DocCheckFailure>().having(
            (DocCheckFailure e) => e.message,
            'message',
            contains('file.bzl'),
          ),
        ),
      );
    });
  });

  group('wire codec', () {
    test('round-trips nested messages and strings', () {
      final Uint8List bytes = sampleMessage();
      final m = WireMessage.parse(bytes);
      expect(m.string(1), 'héllo');
      expect(m.message(2)!.integer(1), 300);
    });
    test('a truncated message fails', () {
      final Uint8List bytes = sampleMessage();
      expect(
        () => WireMessage.parse(
          Uint8List.sublistView(bytes, 0, bytes.length - 1),
        ),
        throwsFormatException,
      );
    });
  });

  group('command line', () {
    late Directory dir;
    late String extract;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('doc_check_test');
      Directory('${dir.path}/pkg').createSync();
      File('${dir.path}/pkg/lib.bzl')
          .writeAsStringSync('def f(p):\n    return p\n');
      extract = '${dir.path}/lib.binaryproto';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    int exec(List<String> args, StringBuffer out, StringBuffer err) =>
        run([...args, '--sources-root=${dir.path}', extract], out, err);

    test('--emit-rule-kinds prints file, kind and name', () {
      File(extract).writeAsBytesSync(
        module(
          rules: [
            rule('a_rule'),
            rule('a_test', test: true),
            rule('a_bin', executable: true),
          ],
          macros: [macro('a_macro')],
          aspects: [aspect('an_aspect')],
          repoRules: [repoRule('a_repo')],
          extensions: [extension('an_ext')],
        ),
      );
      final out = StringBuffer();
      expect(exec(['--emit-rule-kinds'], out, StringBuffer()), 0);
      expect(
        out.toString().split('\n').where((l) => l.isNotEmpty).toSet(),
        {
          '//pkg:lib.bzl\trule\ta_rule',
          '//pkg:lib.bzl\ttest_rule\ta_test',
          '//pkg:lib.bzl\texecutable_rule\ta_bin',
          '//pkg:lib.bzl\tmacro\ta_macro',
          '//pkg:lib.bzl\taspect\tan_aspect',
          '//pkg:lib.bzl\trepository_rule\ta_repo',
          '//pkg:lib.bzl\tmodule_extension\tan_ext',
        },
      );
    });

    test('--emit-api prints attributes, fields and parameters', () {
      File(extract).writeAsBytesSync(
        module(
          rules: [
            rule(
              'r',
              attrs: [
                attr('name', native: true, mandatory: true, type: 1),
                attr('mode', defaultValue: '"release"'),
              ],
            ),
          ],
          funcs: [
            func(
              'f',
              params: [
                param('p'),
                param('opt', defaultValue: 'None', role: 3),
                param('kwargs', role: 5),
              ],
            ),
          ],
          providers: [
            provider('P', fields: [('x', goodDoc)]),
          ],
        ),
      );
      final out = StringBuffer();
      expect(exec(['--emit-api'], out, StringBuffer()), 0);
      expect(out.toString(), '''
file //pkg:lib.bzl
  symbol rule r
    attr name type=NAME mandatory=true natively_defined=true default=
    attr mode type=STRING mandatory=false natively_defined=false default="release"
  symbol provider P
    field x
  symbol function f
    param p role=ordinary mandatory=true default=
    param opt role=keyword-only mandatory=false default=None
    param kwargs role=kwargs mandatory=true default=
''');
    });

    test('a gap is reported as file:symbol: rule with exit 1', () {
      File(extract).writeAsBytesSync(
        module(
          funcs: [
            func('f', params: [param('p', doc: '')]),
          ],
        ),
      );
      final err = StringBuffer();
      expect(exec([], StringBuffer(), err), 1);
      expect(err.toString(), contains('//pkg:lib.bzl:f.p: param-doc-missing'));
      expect(err.toString(), contains('//pkg:lib.bzl:f: returns-missing'));
    });

    test('a missing extract fails and names it', () {
      final err = StringBuffer();
      expect(exec([], StringBuffer(), err), 2);
      expect(err.toString(), contains('lib.binaryproto is missing'));
    });

    test('a missing source file fails and names it', () {
      File('${dir.path}/pkg/lib.bzl').deleteSync();
      File(extract).writeAsBytesSync(module(funcs: [func('g')]));
      final err = StringBuffer();
      expect(exec([], StringBuffer(), err), 2);
      expect(err.toString(), contains('lib.bzl'));
    });
  });
}

/// A small message: field 1 = "héllo", field 2 = {1: 300}.
Uint8List sampleMessage() =>
    (ProtoWriter()
          ..str(1, 'héllo')
          ..msg(2, ProtoWriter()..varint(1, 300)))
        .bytes();
