import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pub_semver/pub_semver.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'format_runner.dart' show resolveFormatMode, runFormatRequest;

late List<String> _sdkDartPaths;

/// The `format_runner` kernel binary under test (first test arg). Empty on
/// direct `dart path/to/format_runner_test.dart` runs, where the binary is
/// unavailable; the worker subprocess test below skips itself in that case.
late String _toolDillPath;
late Directory _tmp;

void main(List<String> args) {
  final r = Runfiles.create();
  if (args.length >= 3) {
    _toolDillPath = r.rlocation(args.first);
    _sdkDartPaths = [for (final a in args.sublist(1)) r.rlocation(a)];
  } else {
    _toolDillPath = '';
    _sdkDartPaths = [for (final a in args) r.rlocation(a)];
  }

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('format_runner_test.');
  });

  tearDown(() {
    _tmp.deleteSync(recursive: true);
  });

  test(
    'resolveFormatMode matches Starlark gate across SDKs and language versions',
    () {
      final mLatest3135 = resolveFormatMode('3.13.5', 'latest');
      expect(mLatest3135.inProcess, isTrue);
      expect(mLatest3135.languageVersion, '3.13');
      expect(mLatest3135.parsedLanguageVersion, Version(3, 13, 0));
      expect(mLatest3135.sdkLanguageVersion, Version(3, 13, 0));

      final mEmpty3134 = resolveFormatMode('3.13.4', '');
      expect(mEmpty3134.inProcess, isTrue);
      expect(mEmpty3134.languageVersion, '3.13');
      expect(mEmpty3134.parsedLanguageVersion, Version(3, 13, 0));

      final mShort = resolveFormatMode('3.13.5', '3.6');
      expect(mShort.inProcess, isTrue);
      expect(mShort.languageVersion, '3.6');
      expect(mShort.parsedLanguageVersion, Version(3, 6, 0));

      final mMin = resolveFormatMode('3.13.4', '2.12');
      expect(mMin.inProcess, isTrue);
      expect(mMin.languageVersion, '2.12');

      final mMax2x = resolveFormatMode('3.13.5', '2.19');
      expect(mMax2x.inProcess, isTrue);
      expect(mMax2x.languageVersion, '2.19');

      // Out-of-range or non-existent language versions fall back to CLI.
      final mInvalid2x = resolveFormatMode('3.13.5', '2.20');
      expect(mInvalid2x.inProcess, isFalse);
      expect(mInvalid2x.languageVersion, '2.20');
      expect(mInvalid2x.parsedLanguageVersion, isNull);

      final mPreNullSafety = resolveFormatMode('3.13.5', '2.11');
      expect(mPreNullSafety.inProcess, isFalse);
      expect(mPreNullSafety.languageVersion, '2.11');

      final mFutureLv = resolveFormatMode('3.13.5', '3.14');
      expect(mFutureLv.inProcess, isFalse);
      expect(mFutureLv.languageVersion, '3.14');

      // Other SDK versions fall back to the SDK's own dart format CLI and map
      // `latest` to the SDK's `<major>.<minor>`, never 3.14.
      final mOldPatch = resolveFormatMode('3.13.3', 'latest');
      expect(mOldPatch.inProcess, isFalse);
      expect(mOldPatch.languageVersion, '3.13');

      final mSdk311 = resolveFormatMode('3.11.0', 'latest');
      expect(mSdk311.inProcess, isFalse);
      expect(mSdk311.languageVersion, '3.11');

      final mSdk314 = resolveFormatMode('3.14.0-100.0.dev', 'latest');
      expect(mSdk314.inProcess, isFalse);
      expect(mSdk314.languageVersion, '3.14');
    },
  );

  test('format_runner agrees with SDK dart format on accepted and rewritten files across two supported SDKs', () async {
    expect(_sdkDartPaths.length, greaterThanOrEqualTo(2));
    final seenSdkVersions = <String>{};

    for (final dartBin in _sdkDartPaths) {
      final sdkRoot = File(dartBin).parent.parent.path;
      final sdkVersion = File('$sdkRoot/version').readAsStringSync().trim();
      seenSdkVersions.add(sdkVersion);

      final cases =
          <
            ({
              String name,
              String languageVersion,
              String? optionsYaml,
              String content,
              bool expectPass,
            })
          >[
            (
              name: 'tall_accepted',
              languageVersion: 'latest',
              optionsYaml: null,
              content: "void main() {\n  print('hello');\n}\n",
              expectPass: true,
            ),
            (
              name: 'tall_rewritten',
              languageVersion: 'latest',
              optionsYaml: null,
              content: "void main() {   print('hello'); }\n",
              expectPass: false,
            ),
            (
              name: 'short_3_6_accepted',
              languageVersion: '3.6',
              optionsYaml: null,
              content:
                  'int sum(\n'
                  '  int firstOperandWithALongName,\n'
                  '  int secondOperandWithALongName,\n'
                  ') =>\n'
                  '    firstOperandWithALongName + secondOperandWithALongName;\n',
              expectPass: true,
            ),
            (
              name: 'short_3_6_rewritten',
              languageVersion: '3.6',
              optionsYaml: null,
              content:
                  'int sum(\n'
                  '  int firstOperandWithALongName,\n'
                  '  int secondOperandWithALongName,\n'
                  ') => firstOperandWithALongName +\n'
                  '    secondOperandWithALongName;\n',
              expectPass: false,
            ),
            (
              name: 'preserve_trailing_commas_accepted',
              languageVersion: 'latest',
              optionsYaml: 'formatter:\n  trailing_commas: preserve\n',
              content: 'void f(\n  int a,\n) {}\n',
              expectPass: true,
            ),
            (
              name: 'automate_trailing_commas_rewritten',
              languageVersion: 'latest',
              optionsYaml: null,
              content: 'void f(\n  int a,\n) {}\n',
              expectPass: false,
            ),
            (
              name: 'override_above_sdk_rejected',
              languageVersion: '3.6',
              optionsYaml: null,
              content:
                  '// @dart=3.14\nclass Point(final int x, final int y);\n',
              expectPass: false,
            ),
            (
              name: 'cli_fallback_accepted',
              languageVersion: '2.12',
              optionsYaml: null,
              content: 'void main() {}\n',
              expectPass: true,
            ),
            (
              name: 'cli_fallback_rewritten',
              languageVersion: '2.12',
              optionsYaml: null,
              content: 'void main() {  }\n',
              expectPass: false,
            ),
          ];

      for (final c in cases) {
        final caseDir = Directory('${_tmp.path}/${sdkVersion}_${c.name}')
          ..createSync(recursive: true);
        final projDir = Directory('${caseDir.path}/proj');
        Directory('${projDir.path}/src/pkg/lib').createSync(recursive: true);
        Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
        File('${projDir.path}/.dart_tool/package_config.json')
            .writeAsStringSync(
              jsonEncode({'configVersion': 2, 'packages': <Object?>[]}),
            );
        final relFiles = <String>['pkg/lib/a.dart'];
        if (c.optionsYaml != null) {
          File('${projDir.path}/src/pkg/analysis_options.yaml')
              .writeAsStringSync(c.optionsYaml!);
          relFiles.add('pkg/analysis_options.yaml');
        }
        final srcFile = File('${projDir.path}/src/pkg/lib/a.dart')
          ..writeAsStringSync(c.content);
        File('${projDir.path}/.dart_tool/src_manifest.txt')
            .writeAsStringSync('${relFiles.join('\n')}\n');

        // 1. Run the SDK's own `dart format` CLI directly to verify ground truth.
        final resolvedLv = resolveFormatMode(
          sdkVersion,
          c.languageVersion,
        ).languageVersion;
        final sdkRes = Process.runSync(
          dartBin,
          [
            'format',
            '--output=none',
            '--set-exit-if-changed',
            '--language-version=$resolvedLv',
            srcFile.path,
          ],
          environment: dartBin.endsWith('.exe')
              ? {'USERPROFILE': caseDir.path, 'LOCALAPPDATA': caseDir.path}
              : {'HOME': caseDir.path},
        );
        expect(
          sdkRes.exitCode == 0,
          c.expectPass,
          reason:
              'SDK $sdkVersion dart format on ${c.name}: '
              'exit=${sdkRes.exitCode}\n${sdkRes.stdout}\n${sdkRes.stderr}',
        );

        // 2. Run format_runner in its normal mode for this SDK and languageVersion.
        final manifest = File('${caseDir.path}/manifest.txt')
          ..writeAsStringSync('src/pkg/lib/a.dart\n');
        final stamp = File('${caseDir.path}/stamp');
        final outBuf = StringBuffer();
        final errBuf = StringBuffer();
        final runnerExit = await runFormatRequest(
          [
            '--dart',
            dartBin,
            '--sdk-version',
            sdkVersion,
            '--project',
            projDir.path,
            '--manifest',
            manifest.path,
            '--stamp',
            stamp.path,
            '--language-version',
            c.languageVersion,
          ],
          outSink: outBuf,
          errSink: errBuf,
        );
        expect(
          runnerExit == 0,
          c.expectPass,
          reason:
              'format_runner on SDK $sdkVersion (${c.name}): '
              'exit=$runnerExit\n$outBuf\n$errBuf',
        );
        expect(stamp.existsSync(), c.expectPass);

        // 3. Also verify CLI fallback mode explicitly (`--sdk-version 3.11.0`)
        // against this SDK's `dart format` binary.
        final cliStamp = File('${caseDir.path}/cli_stamp');
        final cliOut = StringBuffer();
        final cliErr = StringBuffer();
        final cliExit = await runFormatRequest(
          [
            '--dart',
            dartBin,
            '--sdk-version',
            '3.11.0',
            '--project',
            projDir.path,
            '--manifest',
            manifest.path,
            '--stamp',
            cliStamp.path,
            '--language-version',
            resolvedLv,
          ],
          outSink: cliOut,
          errSink: cliErr,
        );
        expect(
          cliExit == 0,
          c.expectPass,
          reason:
              'format_runner CLI fallback on SDK $sdkVersion (${c.name}): '
              'exit=$cliExit\n$cliOut\n$cliErr',
        );
        expect(cliStamp.existsSync(), c.expectPass);
      }
    }

    expect(
      seenSdkVersions.length,
      greaterThanOrEqualTo(2),
      reason:
          'Expected at least two distinct supported SDK versions, got $seenSdkVersions',
    );
  });

  test(
    'an unreadable package config falls back to stock formatter options',
    () async {
      // Drives `findDirPackageConfig` with configs `findPackageConfig`
      // rejects: malformed JSON (`FormatException`) and a config version
      // from the future (`PackageConfigError`, an `ArgumentError`). Both
      // must fall back exactly like a config with no packages: the
      // `package:` include stays unresolvable, formatting runs at stock
      // defaults, and no error escapes `runFormatRequest`.
      final dartBin = _sdkDartPaths.first;
      final sdkVersion = File('${File(dartBin).parent.parent.path}/version')
          .readAsStringSync()
          .trim();
      expect(
        resolveFormatMode(sdkVersion, 'latest').inProcess,
        isTrue,
        reason: 'the config fallback lives in the in-process formatter',
      );
      final configs = <String, String>{
        'malformed': '{not json\n',
        'future_version': '{"configVersion": 999, "packages": []}',
        'empty': '{"configVersion": 2, "packages": []}',
      };
      for (final entry in configs.entries) {
        final caseDir = Directory('${_tmp.path}/bad_config_${entry.key}')
          ..createSync(recursive: true);
        final projDir = Directory('${caseDir.path}/proj')
          ..createSync(recursive: true);
        Directory('${projDir.path}/src/pkg/lib').createSync(recursive: true);
        Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
        File('${projDir.path}/.dart_tool/package_config.json')
            .writeAsStringSync(entry.value);
        File('${projDir.path}/src/pkg/analysis_options.yaml')
            .writeAsStringSync('include: package:fake_pkg/options.yaml\n');
        File('${projDir.path}/src/pkg/lib/a.dart')
            .writeAsStringSync("void main() {\n  print('hello');\n}\n");
        final manifest = File('${caseDir.path}/manifest.txt')
          ..writeAsStringSync('src/pkg/lib/a.dart\n');
        final stamp = File('${caseDir.path}/stamp');
        final outBuf = StringBuffer();
        final errBuf = StringBuffer();
        final exit = await runFormatRequest(
          [
            '--dart',
            dartBin,
            '--sdk-version',
            sdkVersion,
            '--project',
            projDir.path,
            '--manifest',
            manifest.path,
            '--stamp',
            stamp.path,
            '--language-version',
            'latest',
          ],
          outSink: outBuf,
          errSink: errBuf,
        );
        expect(
          exit,
          1,
          reason:
              '${entry.key}: an unresolvable package include warns and fails '
              'the check\n$outBuf\n$errBuf',
        );
        expect(
          errBuf.toString(),
          contains('Package resolution error'),
          reason:
              '${entry.key}: the config failure must surface as a '
              'resolution warning, not an escape\n$outBuf\n$errBuf',
        );
        expect(stamp.existsSync(), isFalse);
      }
    },
  );

  test(
    'persistent worker answers a failing request and logs to stderr',
    () async {
      if (_toolDillPath.isEmpty) return;
      final dartBin = _sdkDartPaths.first;
      final proc = await Process.start(dartBin, [
        _toolDillPath,
        '--persistent_worker',
      ]);
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      // A `@`-file that does not exist: param expansion throws before any
      // formatting runs, exercising the worker's top-level handler.
      proc.stdin.add(
        _requestFrameForTest(['@${_tmp.path}/no-such-param-file.txt'], 3),
      );
      await proc.stdin.flush();
      final (code, output, requestId) = await _readResponseForTest(proc.stdout)
          .timeout(const Duration(minutes: 2));
      expect(requestId, 3);
      expect(code, 1);
      expect(output, contains('unhandled exception'));
      await proc.stdin.close();
      expect(await proc.exitCode, 0);
      expect(await stderrFuture, contains('unhandled exception'));
    },
  );
}

void _writeVarintForTest(BytesBuilder out, int value) {
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

/// One framed `WorkRequest` carrying [arguments] as request [requestId].
Uint8List _requestFrameForTest(List<String> arguments, int requestId) {
  final message = BytesBuilder();
  for (final argument in arguments) {
    message.addByte(0x0a);
    final bytes = utf8.encode(argument);
    _writeVarintForTest(message, bytes.length);
    message.add(bytes);
  }
  message.addByte(0x18);
  _writeVarintForTest(message, requestId);
  final frame = BytesBuilder();
  final payload = message.toBytes();
  _writeVarintForTest(frame, payload.length);
  frame.add(payload);
  return frame.toBytes();
}

/// Reads one framed `WorkResponse` as (exit code, output, request id).
Future<(int, String, int)> _readResponseForTest(
  Stream<List<int>> source,
) async {
  final buf = <int>[];
  var pos = 0;
  final it = StreamIterator<List<int>>(source);
  Future<int> byte() async {
    while (pos >= buf.length) {
      if (!await it.moveNext()) {
        throw StateError('worker stdout ended mid-response');
      }
      buf.addAll(it.current);
    }
    return buf[pos++];
  }

  Future<int> varint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = await byte();
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  Future<Uint8List> bytes(int n) async {
    final out = <int>[];
    while (out.length < n) {
      out.add(await byte());
    }
    return Uint8List.fromList(out);
  }

  final payload = await bytes(await varint());
  var exitCode = 0;
  var output = '';
  var requestId = 0;
  var p = 0;
  int v() {
    var r = 0;
    var s = 0;
    while (true) {
      final b = payload[p++];
      r |= (b & 0x7f) << s;
      if (b < 0x80) return r;
      s += 7;
    }
  }

  while (p < payload.length) {
    switch (v()) {
      case 0x08:
        exitCode = v();
      case 0x12:
        final n = v();
        output = utf8.decode(payload.sublist(p, p + n));
        p += n;
      case 0x18:
        requestId = v();
      default:
        throw StateError('unexpected WorkResponse field');
    }
  }
  return (exitCode, output, requestId);
}
