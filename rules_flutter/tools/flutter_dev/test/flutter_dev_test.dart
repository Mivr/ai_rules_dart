// The whole tool against a fake `bazel` and a fake stock `flutter`, both shell scripts this test
// writes. The fake Bazel copies a prepared build event file to where it is asked to write one;
// the outputs it names are files this test creates. The fake flutter records its arguments and
// speaks enough of the `--machine` protocol (or of the pid-file and SIGUSR2 contract) to start an
// app and answer one restart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/flutter_dev.dart';
import 'package:test/test.dart';

late Directory tmp;
late String ws;
late String execRoot;
late String sdk;

String get _log => '${tmp.path}/log';

void _write(String path, String content, {bool executable = false}) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  if (executable) Process.runSync('chmod', <String>['+x', path]);
}

Map<String, Object?> _file(String path) {
  final List<String> parts = path.split('/');
  return <String, Object?>{
    'name': parts.last,
    'pathPrefix': parts.sublist(0, parts.length - 1),
  };
}

/// A build event file: [groups] maps a label and output group to its files.
String _events(Map<(String, String), List<String>> groups) {
  final lines = <Map<String, Object?>>[
    <String, Object?>{
      'id': <String, Object?>{'workspace': <String, Object?>{}},
      'workspaceInfo': <String, Object?>{'localExecRoot': execRoot},
    },
  ];
  var n = 0;
  groups.forEach(((String, String) key, List<String> files) {
    n++;
    lines.add(<String, Object?>{
      'id': <String, Object?>{
        'namedSet': <String, Object?>{'id': '$n'},
      },
      'namedSetOfFiles': <String, Object?>{'files': files.map(_file).toList()},
    });
    lines.add(<String, Object?>{
      'id': <String, Object?>{
        'targetCompleted': <String, Object?>{
          'label': key.$1,
          if (key.$2 != 'default') 'aspect': 'a',
        },
      },
      'completed': <String, Object?>{
        'outputGroup': <Object?>[
          <String, Object?>{
            'name': key.$2,
            'fileSets': <Object?>[
              <String, Object?>{'id': '$n'},
            ],
          },
        ],
      },
    });
  });
  return lines.map(jsonEncode).join('\n');
}

void main() {
  setUp(() {
    tmp = Directory.systemTemp
        .createTempSync('flutter_dev_test')
        .resolveSymbolicLinksSync()
        .let(Directory.new);
    ws = '${tmp.path}/ws';
    execRoot = '${tmp.path}/ob/execroot/_main';
    sdk = '${tmp.path}/sdk';
    _write('$ws/MODULE.bazel', '');
    _write('$ws/pubspec.yaml', 'name: counter\n');
    _write(
      '$sdk/bin/cache/flutter.version.json',
      jsonEncode(<String, Object?>{'flutterVersion': '3.47.7'}),
    );
    const st = 'bazel-out/k8-dbg-ST-1/bin';
    const top = 'bazel-out/k8-dbg/bin';
    _write(
      '$execRoot/$st/app_flutter.flutter_stock_dev.json',
      jsonEncode(<String, Object?>{
        'flutterVersion': '3.47.7',
        'label': '@@//:app_flutter',
        'package': 'counter',
        'packageConfig': '$st/app_flutter.package_config.json',
      }),
    );
    _write(
      '$execRoot/$st/app_flutter.package_config.json',
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'packages': <Object?>[
          <String, Object?>{
            'name': 'flutter',
            'rootUri': 'org-dartlang-app:///external/hub__flutter',
            'packageUri': 'lib/',
          },
          <String, Object?>{
            'name': 'counter',
            'rootUri': 'org-dartlang-app:///',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    _write('$execRoot/$st/lib/l10n/x.dart', '// in the app configuration');
    _write(
      '$execRoot/$top/lib/l10n/x.dart',
      '// in the top-level configuration',
    );
    _write(
      '$execRoot/$st/app_flutter.flutter_stock_dev_generated.json',
      jsonEncode(<String, Object?>{
        'sources': <String, Object?>{'lib/l10n/x.dart': '@@//:l10n'},
      }),
    );
    _write(
      '$execRoot/$st/l10n.flutter_stock_dev_generated.json',
      jsonEncode(<String, Object?>{
        'stockGenerator': 'gen-l10n',
        'label': '@@//:l10n',
      }),
    );
    _write('$execRoot/$top/app.apk', 'apk');
    final appGroups = <(String, String), List<String>>{
      ('//:app', 'default'): <String>['$top/app.apk'],
      ('//:app', 'flutter_stock_dev'): <String>[
        '$st/app_flutter.flutter_stock_dev.json',
        '$st/app_flutter.package_config.json',
      ],
      ('//:app', 'flutter_stock_dev_generated'): <String>[
        '$st/l10n.flutter_stock_dev_generated.json',
        '$st/lib/l10n/x.dart',
        '$st/app_flutter.flutter_stock_dev_generated.json',
      ],
    };
    _write('${tmp.path}/bep_app.json', _events(appGroups));
    _write(
      '${tmp.path}/bep_gen.json',
      _events(<(String, String), List<String>>{
        ('//:l10n', 'default'): <String>['$top/lib/l10n/x.dart'],
      }),
    );
    _write('${tmp.path}/bazel', '''
#!/bin/sh
echo "bazel \$*" >> $_log
for a in "\$@"; do case "\$a" in --build_event_json_file=*) out="\${a#--build_event_json_file=}";; esac; done
if [ -f ${tmp.path}/bazel_fails ]; then exit 3; fi
case "\$*" in *--aspects*) cp ${tmp.path}/bep_app.json "\$out";; *) cp ${tmp.path}/bep_gen.json "\$out";; esac
''', executable: true);
    _write('$sdk/bin/flutter', '''
#!/bin/sh
echo "flutter \$*" >> $_log
[ "\$1" = --version ] && exit 0
case "\$*" in
  *--machine*)
    echo 'Launching'
    echo '[{"event":"app.start","params":{"appId":"a1"}}]'
    echo '[{"event":"app.started","params":{"appId":"a1"}}]'
    read request
    echo "request \$request" >> $_log
    echo '[{"id":"flutter_dev.restart","result":{"code":0,"message":""}}]'
    echo '[{"event":"app.stop","params":{"appId":"a1"}}]'
    ;;
  *)
    while [ \$# -gt 0 ]; do [ "\$1" = --pid-file ] && pidfile="\$2"; shift; done
    trap 'echo "signal USR2" >> $_log; exit 0' USR2
    echo \$\$ > "\$pidfile"
    i=0; while [ \$i -lt 100 ]; do sleep 0.1; i=\$((i+1)); done
    exit 9
    ;;
esac
''', executable: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, String> env() => <String, String>{
    'BUILD_WORKING_DIRECTORY': ws,
    'BUILD_WORKSPACE_DIRECTORY': ws,
    'BAZEL': '${tmp.path}/bazel',
    'FLUTTER_ROOT': sdk,
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
  };
  List<String> log() =>
      File(_log).existsSync() ? File(_log).readAsLinesSync() : <String>[];

  test('run --machine: builds, writes the project files, links, runs the stock tool, restarts once', () async {
    final input = StreamController<List<int>>();
    final outFile = File('${tmp.path}/stdout');
    final IOSink output = outFile.openWrite();
    final int code = await flutterDev(
      <String>[
        'run',
        '--machine',
        '--bazel-target=//:app',
        '-d',
        'emulator-5584',
      ],
      self: '${tmp.path}/flutter_dev',
      environment: env(),
      input: input.stream,
      output: output,
    );
    await output.close();
    await input.close();
    expect(code, 0);

    final List<String> lines = log();
    expect(
      lines[0],
      allOf(
        contains('bazel build -c dbg'),
        contains(
          '--output_groups=+flutter_stock_dev,+flutter_stock_dev_generated',
        ),
        endsWith('-- //:app'),
      ),
    );
    // The generator was not known yet, so it gets a build of its own in the top-level configuration.
    expect(
      lines[1],
      allOf(
        startsWith('bazel build -c dbg'),
        isNot(contains('--aspects')),
        endsWith('-- //:l10n'),
      ),
    );
    expect(
      lines[2],
      'flutter run --no-pub --use-application-binary $execRoot/bazel-out/k8-dbg/bin/app.apk --machine -d emulator-5584',
    );
    expect(
      lines[3],
      allOf(contains('"app.restart"'), contains('"fullRestart":true')),
    );

    // The client never sees the injected request's answer, and sees app.started after it.
    expect(outFile.readAsLinesSync(), <String>[
      'Launching',
      '[{"event":"app.start","params":{"appId":"a1"}}]',
      '[{"event":"app.started","params":{"appId":"a1"}}]',
      '[{"event":"app.stop","params":{"appId":"a1"}}]',
    ]);

    final config = jsonDecode(
      File('$ws/.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final roots = <String, Object?>{
      for (final p
          in (config['packages']! as List<Object?>)
              .cast<Map<String, Object?>>())
        p['name']! as String: p['rootUri'],
    };
    expect(roots['counter'], Uri.directory(ws).toString());
    expect(
      roots['flutter'],
      Uri.directory('${tmp.path}/ob/external/hub__flutter').toString(),
    );
    expect(
      roots['sky_engine'],
      Uri.directory('$sdk/bin/cache/pkg/sky_engine').toString(),
    );
    expect(File('$ws/.dart_tool/package_graph.json').existsSync(), isTrue);
    // Linked at the source path, to the top-level output a `bazel build //:l10n` rewrites.
    expect(
      Link('$ws/lib/l10n/x.dart').targetSync(),
      '$execRoot/bazel-out/k8-dbg/bin/lib/l10n/x.dart',
    );

    // The next run builds the known generator together with the app, in one invocation.
    File(_log).deleteSync();
    await flutterDev(
      <String>['run', '--machine', '--bazel-target=//:app'],
      self: '${tmp.path}/flutter_dev',
      environment: env(),
      input: const Stream<List<int>>.empty(),
      output: File('${tmp.path}/stdout2').openWrite(),
    );
    expect(log().where((String l) => l.startsWith('bazel ')), <Matcher>[
      endsWith('-- //:app //:l10n'),
    ]);
  });

  test('run in a terminal: the restart is SIGUSR2 once the stock tool wrote its pid file', () async {
    final int code = await flutterDev(
      <String>['run', '--bazel-target=//:app'],
      self: '${tmp.path}/flutter_dev',
      environment: env(),
    );
    expect(code, 0, reason: 'the fake exits 0 on SIGUSR2 and 9 without it');
    expect(log(), contains('signal USR2'));
    expect(
      log().firstWhere((String l) => l.startsWith('flutter ')),
      contains('--pid-file $ws/.dart_tool/flutter_dev/flutter.pid'),
    );
  });

  test(
    'with l10n.yaml the stock tool generates: no link, no generator build',
    () async {
      _write('$ws/l10n.yaml', 'arb-dir: lib/l10n\n');
      await flutterDev(
        <String>[
          'run',
          '--machine',
          '--bazel-target=//:app',
          '--bazel-no-restart',
        ],
        self: '${tmp.path}/flutter_dev',
        environment: env(),
        input: Stream<List<int>>.value(utf8.encode('{}\n')),
        output: File('${tmp.path}/stdout').openWrite(),
      );
      expect(log().where((String l) => l.startsWith('bazel ')), hasLength(1));
      expect(
        FileSystemEntity.typeSync('$ws/lib/l10n/x.dart', followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
  );

  test('web: no app binary, only the aspect groups, and no restart', () async {
    await flutterDev(
      <String>['run', '--machine', '--bazel-target=//:app', '-d', 'chrome'],
      self: '${tmp.path}/flutter_dev',
      environment: env(),
      input: Stream<List<int>>.value(utf8.encode('{}\n')),
      output: File('${tmp.path}/stdout').openWrite(),
    );
    final List<String> lines = log();
    expect(
      lines[0],
      contains(
        '--output_groups=flutter_stock_dev,flutter_stock_dev_generated ',
      ),
    );
    expect(
      lines.firstWhere((String l) => l.startsWith('flutter ')),
      'flutter run --no-pub --machine -d chrome',
    );
    expect(
      lines.where((String l) => l.startsWith('request ')),
      hasLength(1),
      reason: 'the input line, not a restart',
    );
    expect(
      lines.firstWhere((String l) => l.startsWith('request ')),
      'request {}',
    );
  });

  test(
    "a failed build stops with Bazel's exit code, before the stock tool",
    () async {
      _write('${tmp.path}/bazel_fails', '');
      final int code = await flutterDev(
        <String>['run', '--bazel-target=//:app'],
        self: '${tmp.path}/flutter_dev',
        environment: env(),
      );
      expect(code, 3);
      expect(log().where((String l) => l.startsWith('flutter ')), isEmpty);
    },
  );

  test('another stock version is refused unless allowed', () async {
    _write(
      '$sdk/bin/cache/flutter.version.json',
      jsonEncode(<String, Object?>{'flutterVersion': '3.44.0'}),
    );
    expect(
      await flutterDev(
        <String>['run', '--bazel-target=//:app'],
        self: '${tmp.path}/flutter_dev',
        environment: env(),
      ),
      64,
    );
    expect(log().where((String l) => l.startsWith('flutter ')), isEmpty);
  });

  test('no target, or no pubspec, is a usage error', () async {
    expect(
      await flutterDev(
        <String>['run'],
        self: '${tmp.path}/flutter_dev',
        environment: env(),
      ),
      64,
    );
    expect(
      await flutterDev(
        <String>['run', '--bazel-target=//:app'],
        self: '${tmp.path}/flutter_dev',
        environment: env()..['BUILD_WORKING_DIRECTORY'] = tmp.path,
      ),
      64,
    );
  });

  test('ide: the tool copied to a stable path, launch configurations, and an SDK shim that passes through', () async {
    final self = '${tmp.path}/flutter_dev';
    _write(self, '#!/bin/sh\necho "self \$0 \$*" >> $_log\n', executable: true);
    final int code = await flutterDev(
      <String>['ide', '--bazel-target=//:app', '--bazel=${tmp.path}/bazel'],
      self: self,
      environment: env(),
    );
    expect(code, 0);
    final installed = '$ws/.dart_tool/flutter_dev/flutter_dev';
    expect(File(installed).readAsStringSync(), File(self).readAsStringSync());
    final launch = jsonDecode(
      File('$ws/.vscode/launch.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final List<Map<String, Object?>> configs =
        (launch['configurations']! as List<Object?>)
            .cast<Map<String, Object?>>();
    expect(configs.map((Map<String, Object?> c) => c['request']), <String>[
      'launch',
      'attach',
    ]);
    expect(
      configs.first['customTool'],
      r'${workspaceFolder}/.dart_tool/flutter_dev/flutter_dev',
    );
    expect(configs.first['toolArgs'], <String>[
      '--bazel=${tmp.path}/bazel',
      '--bazel-target=//:app',
    ]);
    expect(
      File('$ws/.run/flutter_dev_app.run.xml').readAsStringSync(),
      contains('FlutterRunConfigurationType'),
    );

    final shim = '$ws/.dart_tool/flutter_dev/sdk';
    expect(Link('$shim/bin/cache').targetSync(), '$sdk/bin/cache');
    // The shim's flutter is this tool; run as the shim, a stock command goes to the real SDK.
    final int passed = await flutterDev(
      <String>['--version', '--machine'],
      self: '$shim/bin/flutter',
      environment: const <String, String>{},
    );
    expect(passed, 0);
    expect(log().last, 'flutter --version --machine');
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
