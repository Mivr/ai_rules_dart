// Tagged `runfiles`: the tool under test imports `package:runfiles`, which
// Bazel supplies via the `@rules_dart//dart/runfiles` dep its `dart_test`
// declares. A bare `dart test` resolves only this package's pubspec, where that
// import does not exist, so the file fails to load rather than failing a test.
// Coverage comes from //flutter/private/tools:flutter_test_runner_test.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Imported under a prefix rather than plainly: this script is a `main`, and so
// is the test. Each public member of the runner is public because it is
// reachable from here and nowhere else — see their docstrings.
import '../flutter_test_coverage.dart' as coverage;
import '../flutter_test_runner.dart' as runner;
import '../test_support.dart' as support;

/// A VM service that answers exactly the three RPCs coverage collection makes.
///
/// Real enough to be worth having: it speaks JSON-RPC over a real WebSocket on
/// a real loopback port, so the transport, the framing, and the id/response
/// pairing in `_VmServiceRpc` are all under test rather than mocked away. Each
/// RPC can be told to answer with a JSON-RPC `error` or with a structurally
/// wrong `result`, which is how the tests below reach both failure classes.
class _FakeVmService {
  new _(this._server) {
    _server.listen((request) async {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      // `collectCoverage` closes the socket from its `finally`, including
      // while unwinding a failure, so a mid-conversation close is expected
      // rather than an error.
      socket.listen(
        (raw) {
          final message = json.decode(raw as String) as Map<String, dynamic>;
          final method = message['method'] as String;
          final dynamic id = message['id'];
          onRequest?.call(
            method,
            (message['params'] as Map?)?.cast<String, dynamic>() ?? {},
          );
          final Map<String, dynamic> Function()? handler = handlers[method];
          if (handler == null) {
            socket.add(
              json.encode({
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32601, 'message': 'unexpected RPC: $method'},
              }),
            );
            return;
          }
          socket.add(json.encode({'jsonrpc': '2.0', 'id': id, ...handler()}));
        },
        onDone: () {},
        cancelOnError: true,
      );
    });
  }

  final HttpServer _server;

  /// Called with each request's method and params before it is answered.
  void Function(String method, Map<String, dynamic> params)? onRequest;

  /// Keyed by RPC method; each returns the `result`/`error` half of a reply.
  final handlers = <String, Map<String, dynamic> Function()>{};

  Uri get httpUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<_FakeVmService> start() async =>
      _FakeVmService._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> stop() => _server.close(force: true);
}

/// One isolate, one script, one hit on line 5 and one miss on line 7.
Map<String, dynamic> _oneScriptReport() => {
  'result': {
    'scripts': [
      {'id': 'script-1', 'uri': 'file:///pkg/a.dart'},
    ],
    'ranges': [
      {
        'scriptIndex': 0,
        'coverage': {
          'hits': [10],
          'misses': [20],
        },
      },
    ],
  },
};

/// `[line, tokenPos, column, …]` — token 10 is line 5, token 20 is line 7.
Map<String, dynamic> _tokenTable() => {
  'result': {
    'tokenPosTable': [
      [5, 10, 1],
      [7, 20, 1],
    ],
  },
};

void main() {
  late _FakeVmService vm;
  final sourceReportParams = <Map<String, dynamic>>[];

  setUp(() async {
    vm = await _FakeVmService.start();
    vm.handlers['getVM'] = () => {
      'result': {
        'isolates': [
          {'id': 'iso-1'},
        ],
      },
    };
    sourceReportParams.clear();
    vm.handlers['getSourceReport'] = _oneScriptReport;
    vm.onRequest = (method, params) {
      if (method == 'getSourceReport') sourceReportParams.add(params);
    };
    vm.handlers['getObject'] = _tokenTable;
  });

  tearDown(() => vm.stop());

  group('collectCoverage', () {
    test('renders hits and misses as LCOV line records', () async {
      expect(
        await coverage.collectCoverage(vm.httpUri, const []),
        'SF:/pkg/a.dart\n'
        'DA:5,1\n'
        'DA:7,0\n'
        'end_of_record',
      );
    });

    // These must raise rather than report: an LCOV file missing an isolate,
    // or missing a file inside one, is indistinguishable downstream from a
    // complete one, so the run reads as green with a coverage number that was
    // never measured. The empty-report check only catches losing everything.

    test(
      'raises when an isolate refuses to report, rather than omitting it',
      () async {
        vm.handlers['getSourceReport'] = () => {
          'error': {'code': 112, 'message': 'isolate must be runnable'},
        };

        await expectLater(
          coverage.collectCoverage(vm.httpUri, const []),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('getSourceReport'), contains('must be runnable')),
            ),
          ),
        );
      },
    );

    test('raises when a script token table is refused, rather than dropping '
        'that file', () async {
      vm.handlers['getObject'] = () => {
        'error': {'code': -32602, 'message': 'object id expired'},
      };

      await expectLater(
        coverage.collectCoverage(vm.httpUri, const []),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('getObject'), contains('object id expired')),
          ),
        ),
      );
    });

    test(
      'raises on a malformed report instead of reading it as empty coverage',
      () async {
        // A cast failure inside the LCOV formatter, not an RPC error.
        vm.handlers['getSourceReport'] = () => {
          'result': {
            'scripts': [
              {'id': 42, 'uri': 'file:///pkg/a.dart'},
            ],
            'ranges': const [],
          },
        };

        await expectLater(
          coverage.collectCoverage(vm.httpUri, const []),
          throwsA(isA<TypeError>()),
        );
      },
    );
  });

  group('coverageLibraries', () {
    test('are sent as libraryFilters, exactly as given', () async {
      const scope = ['package:pkg/', 'org-dartlang-app:///test/a_test.dart'];
      await coverage.collectCoverage(vm.httpUri, scope);

      expect(sourceReportParams, hasLength(1));
      expect(sourceReportParams.single['libraryFilters'], scope);
    });

    test('an empty list sends no libraryFilters key', () async {
      await coverage.collectCoverage(vm.httpUri, const []);

      expect(sourceReportParams, hasLength(1));
      expect(sourceReportParams.single.containsKey('libraryFilters'), isFalse);
    });
  });

  group('--test-randomize-ordering-seed', () {
    Map<String, dynamic> tree() => {
      'type': 'group',
      'setUpAll': {'name': 'setUpAll'},
      'tearDownAll': {'name': 'tearDownAll'},
      'entries': [
        for (var i = 0; i < 12; i++) {'type': 'test', 'name': 't$i'},
        {
          'type': 'group',
          'setUpAll': {'name': 'inner setUpAll'},
          'entries': [
            for (var i = 0; i < 12; i++) {'type': 'test', 'name': 'n$i'},
          ],
        },
      ],
    };

    List<String> names(Map<String, dynamic> group) => [
      for (final e in (group['entries'] as List).cast<Map<String, dynamic>>())
        if (e['type'] == 'group') ...names(e) else e['name'] as String,
    ];

    test('no flag leaves the argument list and the seed untouched', () {
      final runner.SeedArgs r = runner.extractSeed(['--update-goldens']);
      expect(r.seed, isNull);
      expect(r.rest, ['--update-goldens']);
    });

    test('an integer seed is removed and combines with --update-goldens', () {
      final runner.SeedArgs r = runner.extractSeed([
        '--test-randomize-ordering-seed=42',
        '--update-goldens',
      ]);
      expect(r.seed, 42);
      expect(r.rest, ['--update-goldens']);
      expect(
        runner.extractSeed([
          '--test-randomize-ordering-seed=0',
        ]).seed,
        0,
      );
    });

    test('random resolves once to an integer', () {
      var calls = 0;
      final runner.SeedArgs r = runner.extractSeed([
        '--test-randomize-ordering-seed=random',
      ], randomSeed: () => ++calls + 6);
      expect(r.seed, 7);
      expect(calls, 1);
      final runner.SeedArgs real = runner.extractSeed([
        '--test-randomize-ordering-seed=random',
      ]);
      expect(real.seed, isNotNull);
      expect(real.seed, greaterThanOrEqualTo(0));
    });

    test('a bad value names the argument', () {
      for (final bad in [
        '--test-randomize-ordering-seed=-1',
        '--test-randomize-ordering-seed=',
        '--test-randomize-ordering-seed=abc',
        '--test-randomize-ordering-seed=1.5',
        '--test-randomize-ordering-seed=99999999999999999999999',
        '--test-randomize-ordering-seed',
      ]) {
        expect(
          () => runner.extractSeed([bad]),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains(bad), contains('--test-randomize-ordering-seed')),
            ),
          ),
          reason: bad,
        );
      }
    });

    test('an unknown argument still reaches the existing rejection', () {
      final runner.SeedArgs r = runner.extractSeed(['--bogus']);
      expect(
        () => runner.parseUpdateGoldens(r.rest, '/ws'),
        throwsA(isA<FormatException>()),
      );
    });

    test('the same seed gives the same order, every case exactly once', () {
      final List<String> base = names(tree());
      final List<String> a = names(runner.shuffleSuite(tree(), 42));
      final List<String> b = names(runner.shuffleSuite(tree(), 42));
      expect(a, b);
      expect(a.toList()..sort(), base.toList()..sort());
      expect(a, isNot(base));
      expect(
        names(runner.shuffleSuite(tree(), 43)),
        isNot(a),
      );
    });

    test('groups keep their fixtures and nesting', () {
      final Map<String, dynamic> s = runner.shuffleSuite(tree(), 7);
      expect((s['setUpAll'] as Map<String, dynamic>)['name'], 'setUpAll');
      expect(
        (s['tearDownAll'] as Map<String, dynamic>)['name'],
        'tearDownAll',
      );
      final List<Map<String, dynamic>> inner = (s['entries'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['type'] == 'group')
          .toList();
      expect(inner, hasLength(1));
      expect(
        (inner.single['setUpAll'] as Map<String, dynamic>)['name'],
        'inner setUpAll',
      );
      expect(names(inner.single), hasLength(12));
    });

    test('a single case is unaffected', () {
      final Map<String, dynamic> one = {
        'type': 'group',
        'entries': [
          {'type': 'test', 'name': 'only'},
        ],
      };
      expect(names(runner.shuffleSuite(one, 5)), ['only']);
    });

    test('the resolved seed is announced on one line a user can copy', () {
      final String line = runner.seedAnnouncement(1234);
      expect(line, isNot(contains('\n')));
      expect(line, contains('--test-randomize-ordering-seed=1234'));
    });
  });

  group('parseUpdateGoldens', () {
    // The refusal is the reason this is a function rather than three lines in
    // `main`: `bazel test` cannot be made to pass and fail the same target, so
    // the only place the rejected case is reachable as a *passing* assertion
    // is here.

    test('is off with no arguments, whether or not a workspace is set', () {
      expect(runner.parseUpdateGoldens([], null), isFalse);
      expect(runner.parseUpdateGoldens([], '/ws'), isFalse);
    });

    test('is on under `bazel run`, which sets BUILD_WORKSPACE_DIRECTORY', () {
      expect(runner.parseUpdateGoldens(['--update-goldens'], '/ws'), isTrue);
    });

    test('refuses under `bazel test`, where there is no source tree to write '
        'to — a golden regenerated into the sandbox would report success and '
        'change nothing', () {
      expect(
        () => runner.parseUpdateGoldens(['--update-goldens'], null),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('bazel run'), contains('--update-goldens')),
          ),
        ),
      );
      expect(
        () => runner.parseUpdateGoldens(['--update-goldens'], ''),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unrecognised argument rather than ignoring it, so a '
        'mistyped flag cannot report a green run that regenerated nothing', () {
      expect(
        () => runner.parseUpdateGoldens(['--update-golden'], '/ws'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--update-golden'),
          ),
        ),
      );
    });
  });

  group('suiteTimeout', () {
    test('is Bazel\'s TEST_TIMEOUT, not package:test\'s 30 seconds', () {
      expect(support.suiteTimeout('300'), {
        'duration': const Duration(seconds: 300).inMicroseconds,
        'scaleFactor': null,
      });
    });

    test('is never none under Bazel, so a test\'s own timeout still fires', () {
      // `Timeout.merge` lets `none` on either side win.
      expect(support.suiteTimeout('60'), isNot('none'));
    });

    test('is none outside bazel test, where there is no limit to state', () {
      expect(support.suiteTimeout(null), 'none');
      expect(support.suiteTimeout(''), 'none');
    });
  });

  group('testCeiling', () {
    test("derives the wedged-test backstop from Bazel's TEST_TIMEOUT, so a "
        'test given --test_timeout=1200 runs its full length', () {
      expect(support.testCeiling('1200').inSeconds, greaterThan(600));
    });

    test('stays inside the Bazel budget, so a wedged test is reported here '
        'rather than killed from outside with no diagnostic', () {
      expect(support.testCeiling('1200').inSeconds, lessThan(1200));
      expect(support.testCeiling('60').inSeconds, lessThan(60));
    });

    test('falls back to five minutes with no TEST_TIMEOUT — a direct run '
        'outside `bazel test` has no budget to derive one from', () {
      expect(support.testCeiling(null), const Duration(minutes: 5));
      expect(support.testCeiling(''), const Duration(minutes: 5));
      expect(support.testCeiling('not-a-number'), const Duration(minutes: 5));
      expect(support.testCeiling('0'), const Duration(minutes: 5));
    });
  });

  group('coverageBound', () {
    Duration bound(String? t, int elapsedSeconds) =>
        support.coverageBound(t, Duration(seconds: elapsedSeconds));

    test('is the whole ceiling at zero elapsed', () {
      expect(bound('1200', 0), support.testCeiling('1200'));
      expect(bound('1200', 0).inSeconds, 1140);
    });

    test('is the ceiling minus the elapsed time', () {
      expect(bound('1200', 1100), const Duration(seconds: 40));
      expect(bound('1200', 600), const Duration(seconds: 540));
      expect(bound('1200', 600), lessThan(support.testCeiling('1200')));
    });

    test('is one second once the budget is used up', () {
      const one = Duration(seconds: 1);
      expect(bound('1200', 1140), one);
      expect(bound('1200', 5000), one);
    });

    test('falls back to five minutes without a usable TEST_TIMEOUT', () {
      for (final String? t in [null, '', 'not-a-number', '0']) {
        expect(bound(t, 0), const Duration(minutes: 5), reason: '$t');
      }
    });

    test('subtracts the elapsed time exactly', () {
      expect(
        bound('1200', 200) - bound('1200', 300),
        const Duration(seconds: 100),
      );
    });
  });

  group('cleanupQuietly', () {
    test('runs the action and swallows a filesystem race', () {
      var ran = false;
      support.cleanupQuietly(() {
        ran = true;
        throw const FileSystemException('gone', '/tmp/flutter_test_x.dill');
      });
      expect(ran, isTrue);
    });

    test('lets a bug in the cleanup itself propagate', () {
      expect(
        () => support.cleanupQuietly(() => throw StateError('bug')),
        throwsStateError,
      );
    });

    test('deletes a real temp file', () {
      final Directory tmpDir = Directory.systemTemp.createTempSync(
        'cleanup_test_',
      );
      try {
        final file = File('${tmpDir.path}/x.dill')..writeAsStringSync('dill');
        support.cleanupQuietly(file.deleteSync);
        expect(file.existsSync(), isFalse);
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });
  });

  group('teardownQuietly', () {
    test('swallows a peer-gone I/O race and an already-closed race', () async {
      final ran = <String>[];
      await expectLater(
        support.teardownQuietly(() async {
          ran.add('io');
          throw const FileSystemException('connection reset');
        }),
        completes,
      );
      await expectLater(
        support.teardownQuietly(
          () => Future<void>.sync(() {
            ran.add('state');
            throw StateError('closed');
          }),
        ),
        completes,
      );
      // Each step really ran and threw; the race was swallowed, not skipped.
      expect(ran, ['io', 'state']);
    });

    test('lets an unexpected teardown error propagate', () async {
      await expectLater(
        support.teardownQuietly(() async => throw ArgumentError('bug')),
        throwsArgumentError,
      );
    });
  });
}
