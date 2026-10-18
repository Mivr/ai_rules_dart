import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

Uint8List _encodeWorkRequest({
  required List<String> arguments,
  Map<String, Uint8List> inputs = const {},
  int requestId = 0,
}) {
  final body = BytesBuilder(copy: false);
  void writeVarint(BytesBuilder b, int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    b.addByte(v);
  }

  for (final arg in arguments) {
    final bytes = utf8.encode(arg);
    writeVarint(body, (1 << 3) | 2);
    writeVarint(body, bytes.length);
    body.add(bytes);
  }
  inputs.forEach((path, digest) {
    final pathBytes = utf8.encode(path);
    final nested = BytesBuilder(copy: false);
    writeVarint(nested, (1 << 3) | 2);
    writeVarint(nested, pathBytes.length);
    nested.add(pathBytes);
    if (digest.isNotEmpty) {
      writeVarint(nested, (2 << 3) | 2);
      writeVarint(nested, digest.length);
      nested.add(digest);
    }
    final nestedBytes = nested.takeBytes();
    writeVarint(body, (2 << 3) | 2);
    writeVarint(body, nestedBytes.length);
    body.add(nestedBytes);
  });
  if (requestId != 0) {
    writeVarint(body, (3 << 3) | 0);
    writeVarint(body, requestId);
  }
  final payload = body.takeBytes();
  final frame = BytesBuilder(copy: false);
  writeVarint(frame, payload.length);
  frame.add(payload);
  return frame.takeBytes();
}

Stream<Uint8List> _frameStream(Stream<List<int>> source) {
  final controller = StreamController<Uint8List>();
  var buf = Uint8List(0);
  source.listen(
    (chunk) {
      final merged = Uint8List(buf.length + chunk.length);
      merged.setRange(0, buf.length, buf);
      merged.setRange(buf.length, merged.length, chunk);
      buf = merged;
      while (true) {
        var len = 0;
        var shift = 0;
        var pos = 0;
        while (true) {
          if (pos >= buf.length) return;
          final b = buf[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (buf.length < pos + len) return;
        controller.add(Uint8List.sublistView(buf, pos, pos + len));
        buf = Uint8List.sublistView(buf, pos + len);
      }
    },
    onError: controller.addError,
    onDone: controller.close,
  );
  return controller.stream;
}

({int exitCode, String output}) _decodeWorkResponse(Uint8List payload) {
  var pos = 0;
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = payload[pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  var exitCode = 0;
  var output = '';
  while (pos < payload.length) {
    final tag = readVarint();
    switch (tag >> 3) {
      case 1:
        exitCode = readVarint();
      case 2:
        final len = readVarint();
        output = utf8.decode(Uint8List.sublistView(payload, pos, pos + len));
        pos += len;
      case 3:
        readVarint();
      default:
        throw StateError('Unexpected wire tag: $tag');
    }
  }
  return (exitCode: exitCode, output: output);
}

void main(List<String> args) {
  final r = Runfiles.create();
  final formatRunnerDill = r.rlocation(args[0]);
  final analyzerSummaryDill = r.rlocation(args[1]);
  final sdkSummaryPath = r.rlocation(args[2]);
  final analyzeRunnerDill = r.rlocation(args[3]);
  final fixRunnerDill = r.rlocation(args[4]);
  final sdkRoot = File(Platform.resolvedExecutable).parent.parent.path;

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('worker_hardening_test.');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test(
    'analyzer_summary and format_runner are compiled in kernel (.dill) mode',
    () {
      expect(formatRunnerDill, endsWith('.dill'));
      expect(analyzerSummaryDill, endsWith('.dill'));
      expect(File(formatRunnerDill).existsSync(), isTrue);
      expect(File(analyzerSummaryDill).existsSync(), isTrue);
    },
  );

  test('analyzer_summary worker invalidates empty digests and prunes orphaned symlinks', () async {
    Directory('${tmp.path}/pkg_dep/lib').createSync(recursive: true);
    Directory('${tmp.path}/pkg_main/src/lib').createSync(recursive: true);
    Directory('${tmp.path}/pkg_main/.dart_tool').createSync(recursive: true);

    File('${tmp.path}/pkg_dep_packages.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'pkg_dep',
            'rootUri': 'pkg_dep',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );
    File('${tmp.path}/pkg_main/src/pubspec.yaml')
        .writeAsStringSync('name: pkg_main\nenvironment:\n  sdk: ^3.7.0\n');
    File('${tmp.path}/pkg_main/.dart_tool/package_config.json')
        .writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'pkg_dep',
                'rootUri': '../../pkg_dep',
                'packageUri': 'lib/',
                'languageVersion': '3.7',
              },
              {
                'name': 'pkg_main',
                'rootUri': '../src',
                'packageUri': 'lib/',
                'languageVersion': '3.7',
              },
            ],
          }),
        );

    File('${tmp.path}/pkg_dep/lib/dep.dart')
        .writeAsStringSync('int foo() => 1;\n');
    File('${tmp.path}/pkg_main/src/lib/main.dart').writeAsStringSync(
      "import 'package:pkg_dep/dep.dart';\nint callBar() => bar();\n",
    );

    final proc = await Process.start(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      '--persistent_worker',
    ], workingDirectory: tmp.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));

    Future<({int exitCode, String output})> send(
      List<String> arguments, {
      Map<String, Uint8List> inputs = const {},
    }) async {
      proc.stdin.add(_encodeWorkRequest(arguments: arguments, inputs: inputs));
      await proc.stdin.flush();
      expect(await responses.moveNext(), isTrue);
      return _decodeWorkResponse(responses.current);
    }

    // 1. Summarize V1 of pkg_dep (without bar())
    var res = await send([
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'pkg_dep_packages.json',
      '--out',
      'dep.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'pkg_dep/lib/dep.dart',
      '--uri',
      'package:pkg_dep/dep.dart',
    ]);
    expect(res.exitCode, 0, reason: res.output);

    // 2. Analyze pkg_main with an empty digest in WorkRequest.inputs -> fails
    res = await send(
      [
        'analyze',
        '--sdk',
        sdkRoot,
        '--project',
        'pkg_main',
        '--stamp',
        'analyzed.stamp',
        '--sdk-summary',
        sdkSummaryPath,
        '--summary',
        'dep.sum',
      ],
      inputs: {'dep.sum': Uint8List(0)},
    );
    expect(res.exitCode, 1);

    // 3. Update pkg_dep to V2 (adding bar()), re-summarize, and re-analyze
    // with empty digest -> must re-stat and pass (exit 0)
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${tmp.path}/pkg_dep/lib/dep.dart').writeAsStringSync(
      'int foo() => 1;\nint bar() => 2;\nString extra() => "v2";\n',
    );
    res = await send([
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'pkg_dep_packages.json',
      '--out',
      'dep.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'pkg_dep/lib/dep.dart',
      '--uri',
      'package:pkg_dep/dep.dart',
    ]);
    expect(res.exitCode, 0, reason: res.output);

    res = await send(
      [
        'analyze',
        '--sdk',
        sdkRoot,
        '--project',
        'pkg_main',
        '--stamp',
        'analyzed.stamp',
        '--sdk-summary',
        sdkSummaryPath,
        '--summary',
        'dep.sum',
      ],
      inputs: {'dep.sum': Uint8List(0)},
    );
    expect(res.exitCode, 0, reason: res.output);

    // 4. Plant an orphaned symlink in pkg_main/src/lib/removed_bad.dart
    File('${tmp.path}/real_removed_bad.dart')
        .writeAsStringSync("int broken = 'not_an_int';\n");
    Link('${tmp.path}/pkg_main/src/lib/removed_bad.dart')
        .createSync('${tmp.path}/real_removed_bad.dart');
    File('${tmp.path}/pkg_main/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pubspec.yaml\nlib/main.dart\n');

    res = await send([
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      'pkg_main',
      '--stamp',
      'analyzed2.stamp',
      '--sdk-summary',
      sdkSummaryPath,
      '--summary',
      'dep.sum',
    ]);
    expect(res.exitCode, 0, reason: res.output);
    expect(
      FileSystemEntity.typeSync(
        '${tmp.path}/pkg_main/src/lib/removed_bad.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    await responses.cancel();
    await proc.stdin.close();
  });

  test('format_runner does not escape <project>/src into execroot analysis_options.yaml', () async {
    final execroot = Directory('${tmp.path}/execroot')
      ..createSync(recursive: true);
    File('${execroot.path}/analysis_options.yaml').writeAsStringSync(
      'include: package:nonexistent_lints/lints.yaml\n'
      'formatter:\n'
      '  page_width: 40\n',
    );

    final projDir = Directory(
      '${execroot.path}/bazel-out/k8-fastbuild/bin/pkg/target.format.proj',
    );
    Directory('${projDir.path}/src/pkg/lib').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': <Object?>[]}),
    );
    File('${projDir.path}/src/pkg/lib/clean.dart').writeAsStringSync(
      "void main() {\n  print('hello world from a 60-char line that fits in 80');\n}\n",
    );
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/lib/clean.dart\n');
    Link('${projDir.path}/src/analysis_options.yaml')
        .createSync('${execroot.path}/analysis_options.yaml');

    File('${execroot.path}/manifest.txt')
        .writeAsStringSync('src/pkg/lib/clean.dart\n');

    final proc = await Process.start(Platform.resolvedExecutable, [
      formatRunnerDill,
      '--persistent_worker',
    ], workingDirectory: execroot.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));

    proc.stdin.add(
      _encodeWorkRequest(
        arguments: [
          '--project',
          'bazel-out/k8-fastbuild/bin/pkg/target.format.proj',
          '--manifest',
          'manifest.txt',
          '--stamp',
          'formatted.stamp',
          '--language-version',
          'latest',
        ],
      ),
    );
    await proc.stdin.flush();
    expect(await responses.moveNext(), isTrue);
    final resp = _decodeWorkResponse(responses.current);
    expect(resp.exitCode, 0, reason: resp.output);
    expect(resp.output, isEmpty);
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/analysis_options.yaml',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    await responses.cancel();
    await proc.stdin.close();
  });

  test('never prunes symlinks without a manifest and fails on empty manifest or unanalyzed source', () {
    final projDir = Directory('${tmp.path}/no_manifest_proj');
    Directory('${projDir.path}/src/lib').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/pubspec.yaml')
        .writeAsStringSync('name: pkg_a\nenvironment:\n  sdk: ^3.7.0\n');
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'pkg_a',
            'rootUri': '../src',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );

    // Stage a symlinked source file WITHOUT `.dart_tool/src_manifest.txt`.
    final realSrc = File('${tmp.path}/real_a.dart')
      ..writeAsStringSync("int bad = 'not_an_int';\n");
    final symlinkSrc = Link('${projDir.path}/src/lib/a.dart')
      ..createSync(realSrc.path);

    // Without a manifest, `analyzer_summary analyze` must NOT prune the symlink
    // and must analyze it (catching the type error).
    var res = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/no_manifest.stamp',
      '--sdk-summary',
      sdkSummaryPath,
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 1);
    expect(
      FileSystemEntity.typeSync(symlinkSrc.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(File('${tmp.path}/no_manifest.stamp').existsSync(), isFalse);

    // Fix the symlinked file; without a manifest, analysis succeeds and keeps the symlink.
    realSrc.writeAsStringSync('int ok = 42;\n');
    res = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/no_manifest_ok.stamp',
      '--sdk-summary',
      sdkSummaryPath,
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(
      FileSystemEntity.typeSync(symlinkSrc.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(File('${tmp.path}/no_manifest_ok.stamp').existsSync(), isTrue);

    // An `--source` that is missing or not analyzed must fail the action.
    res = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/missing_source.stamp',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'src/lib/nonexistent.dart',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 1);
    expect(File('${tmp.path}/missing_source.stamp').existsSync(), isFalse);

    // Write an empty `src_manifest.txt`: a zero-file analysis of a target must
    // fail (never write a green stamp) in both `analyzer_summary` and `analyze_runner`.
    File('${projDir.path}/.dart_tool/src_manifest.txt').writeAsStringSync('');
    res = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/empty_manifest_summary.stamp',
      '--sdk-summary',
      sdkSummaryPath,
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 1);
    expect(
      File('${tmp.path}/empty_manifest_summary.stamp').existsSync(),
      isFalse,
    );

    res = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/empty_manifest_runner.stamp',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 1);
    expect(
      File('${tmp.path}/empty_manifest_runner.stamp').existsSync(),
      isFalse,
    );
  });

  test('summarize outputs are byte-identical across local, sandboxed, and worker execution', () async {
    // First build a dependency summary (`dep_base.sum`) used by all three strategies.
    Directory('${tmp.path}/dep_base/lib').createSync(recursive: true);
    File('${tmp.path}/dep_base/lib/base.dart')
        .writeAsStringSync('class Base { int id() => 1; }\n');
    File('${tmp.path}/dep_base_packages.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'dep_base',
            'rootUri': 'dep_base',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );
    final baseSum = '${tmp.path}/dep_base.sum';
    final baseRes = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'dep_base_packages.json',
      '--out',
      baseSum,
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'dep_base/lib/base.dart',
      '--uri',
      'package:dep_base/base.dart',
    ], workingDirectory: tmp.path);
    expect(baseRes.exitCode, 0, reason: '${baseRes.stdout}\n${baseRes.stderr}');

    const targetSource =
        "import 'package:dep_base/base.dart';\nclass Sub extends Base {}\n";

    // 1. Local (unsandboxed) directory: contains ambient `pubspec.yaml`,
    // `analysis_options.yaml`, an unlisted sibling `.dart` file in `lib/`, and
    // the dependency's real directory with its own `pubspec.yaml`.
    final localDir = Directory('${tmp.path}/local_execroot')
      ..createSync(recursive: true);
    Directory('${localDir.path}/pkg/lib').createSync(recursive: true);
    File('${localDir.path}/pkg/lib/sub.dart').writeAsStringSync(targetSource);
    File('${localDir.path}/pkg/lib/unlisted_ambient.dart')
        .writeAsStringSync('int ambientExtra = 99;\n');
    File('${localDir.path}/pkg/pubspec.yaml').writeAsStringSync(
      'name: pkg\nversion: 9.9.9\nenvironment:\n  sdk: ^3.7.0\n',
    );
    File('${localDir.path}/pkg/analysis_options.yaml').writeAsStringSync(
      'analyzer:\n  strong-mode:\n    implicit-casts: false\n',
    );
    Directory('${localDir.path}/dep_base/lib').createSync(recursive: true);
    File('${localDir.path}/dep_base/pubspec.yaml')
        .writeAsStringSync('name: dep_base\nversion: 1.0.0\n');
    File('${localDir.path}/packages.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'dep_base',
            'rootUri': '_deps/dep_base',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
          {
            'name': 'pkg',
            'rootUri': 'pkg',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );

    final localRes = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'packages.json',
      '--out',
      'local.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--summary',
      baseSum,
      '--source',
      'pkg/lib/sub.dart',
      '--uri',
      'package:pkg/sub.dart',
    ], workingDirectory: localDir.path);
    expect(
      localRes.exitCode,
      0,
      reason: '${localRes.stdout}\n${localRes.stderr}',
    );

    // 2. Sandboxed directory: contains ONLY the declared inputs (`pkg/lib/sub.dart`
    // and `packages.json`), with no ambient `pubspec.yaml`, `analysis_options.yaml`,
    // or unlisted sibling files.
    final sandboxDir = Directory('${tmp.path}/sandbox_execroot')
      ..createSync(recursive: true);
    Directory('${sandboxDir.path}/pkg/lib').createSync(recursive: true);
    File('${sandboxDir.path}/pkg/lib/sub.dart').writeAsStringSync(targetSource);
    File('${sandboxDir.path}/packages.json').writeAsStringSync(
      File('${localDir.path}/packages.json').readAsStringSync(),
    );

    final sandboxRes = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'packages.json',
      '--out',
      'sandbox.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--summary',
      baseSum,
      '--source',
      'pkg/lib/sub.dart',
      '--uri',
      'package:pkg/sub.dart',
    ], workingDirectory: sandboxDir.path);
    expect(
      sandboxRes.exitCode,
      0,
      reason: '${sandboxRes.stdout}\n${sandboxRes.stderr}',
    );

    // 3. Persistent worker execution in the dirty local directory.
    File('${localDir.path}/pkg/lib/unlisted_ambient.dart')
        .writeAsStringSync('int ambientExtra = 99;\n');
    final proc = await Process.start(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      '--persistent_worker',
    ], workingDirectory: localDir.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));
    proc.stdin.add(
      _encodeWorkRequest(
        arguments: [
          'summarize',
          '--sdk',
          sdkRoot,
          '--packages',
          'packages.json',
          '--out',
          'worker.sum',
          '--sdk-summary',
          sdkSummaryPath,
          '--summary',
          baseSum,
          '--source',
          'pkg/lib/sub.dart',
          '--uri',
          'package:pkg/sub.dart',
        ],
      ),
    );
    await proc.stdin.flush();
    expect(await responses.moveNext(), isTrue);
    final workerRes = _decodeWorkResponse(responses.current);
    expect(workerRes.exitCode, 0, reason: workerRes.output);
    await responses.cancel();
    await proc.stdin.close();

    final localBytes = File('${localDir.path}/local.sum').readAsBytesSync();
    final sandboxBytes = File('${sandboxDir.path}/sandbox.sum')
        .readAsBytesSync();
    final workerBytes = File('${localDir.path}/worker.sum').readAsBytesSync();

    expect(localBytes, isNotEmpty);
    expect(localBytes, equals(sandboxBytes));
    expect(workerBytes, equals(sandboxBytes));
  });

  test('deleting a source file makes it invisible under local strategy across all runners', () {
    final projDir = Directory('${tmp.path}/local_proj');
    Directory('${projDir.path}/src/lib').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/pubspec.yaml')
        .writeAsStringSync('name: local_pkg\nenvironment:\n  sdk: ^3.7.0\n');
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'local_pkg',
            'rootUri': '../src',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );

    final keepSrc = File('${projDir.path}/src/lib/keep.dart')
      ..writeAsStringSync('int validValue() => 1;\n');
    final deletedReal = File('${tmp.path}/deleted_real.dart')
      ..writeAsStringSync("int broken = 'compile_error';\n");

    void plantStaleDeletedFile() {
      final link = Link('${projDir.path}/src/lib/deleted.dart');
      if (FileSystemEntity.typeSync(link.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        link.deleteSync();
      }
      link.createSync(deletedReal.path);
    }

    // While `deleted.dart` is still in `src_manifest.txt`, analysis sees it and fails.
    plantStaleDeletedFile();
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('lib/keep.dart\nlib/deleted.dart\n');
    var res = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/before_delete.stamp',
      '--source',
      'src/lib/keep.dart',
      '--source',
      'src/lib/deleted.dart',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, isNonZero);

    // Delete `lib/deleted.dart` from `srcs` (updating `src_manifest.txt`),
    // while the stale symlink remains in `src/lib/deleted.dart` under local strategy.
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('lib/keep.dart\n');

    // 1. `analyze_runner` (source-mode analysis under local strategy)
    plantStaleDeletedFile();
    res = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/after_delete_runner.stamp',
      '--source',
      'src/lib/keep.dart',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/lib/deleted.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    // 2. `analyzer_summary analyze` (summary-mode analysis under local strategy)
    plantStaleDeletedFile();
    res = Process.runSync(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      projDir.path,
      '--stamp',
      '${tmp.path}/after_delete_summary.stamp',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'src/lib/keep.dart',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/lib/deleted.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    // 3. `format_runner` under local strategy
    plantStaleDeletedFile();
    final formatManifest = File('${tmp.path}/format_manifest.txt')
      ..writeAsStringSync('src/lib/keep.dart\n');
    res = Process.runSync(Platform.resolvedExecutable, [
      formatRunnerDill,
      '--project',
      projDir.path,
      '--manifest',
      formatManifest.path,
      '--stamp',
      '${tmp.path}/after_delete_format.stamp',
      '--language-version',
      'latest',
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/lib/deleted.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    // 4. `fix_runner` under local strategy
    plantStaleDeletedFile();
    final eligibleFile = File('${tmp.path}/eligible.txt')
      ..writeAsStringSync('lib/keep.dart\tpkg/lib/keep.dart\n');
    res = Process.runSync(Platform.resolvedExecutable, [
      fixRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      projDir.path,
      '--scratch',
      '${tmp.path}/fix_scratch',
      '--fixes',
      '${tmp.path}/fixes_out',
      '--manifest',
      '${tmp.path}/fixes_manifest.json',
      '--eligible',
      eligibleFile.path,
    ], workingDirectory: tmp.path);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(keepSrc.existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/lib/deleted.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
    expect(
      File('${tmp.path}/fix_scratch/src/lib/deleted.dart').existsSync(),
      isFalse,
    );
  });

  test('uncovered dependency importing undeclared hidden.dart fails identically across local, sandboxed, and worker strategies', () async {
    // Layout:
    // - package P has a dart_library L (`lib/l.dart`) whose srcs import
    //   `package:P/src/hidden.dart` (and re-export it);
    // - `lib/src/hidden.dart` exists on disk in the real source tree of P,
    //   but is in NO target's `srcs`;
    // - the analysis of L, and of a target T depending on L, takes the
    //   from-source path (staged under `src/` with `.dart_tool/src_manifest.txt`
    //   and `rootUri: "../src/P"`).
    final realDir = Directory('${tmp.path}/real_tree');
    Directory('${realDir.path}/P/lib/src').createSync(recursive: true);
    Directory('${realDir.path}/Q/lib').createSync(recursive: true);
    File('${realDir.path}/P/pubspec.yaml')
        .writeAsStringSync('name: P\nenvironment:\n  sdk: ^3.7.0\n');
    final realL = File('${realDir.path}/P/lib/l.dart')
      ..writeAsStringSync(
        "import 'package:P/src/hidden.dart';\n"
        "export 'package:P/src/hidden.dart';\n"
        'int fromL() => hiddenVal;\n',
      );
    final realHidden = File('${realDir.path}/P/lib/src/hidden.dart')
      ..writeAsStringSync('const int hiddenVal = 7;\n');
    final realT = File('${realDir.path}/Q/lib/t.dart')
      ..writeAsStringSync(
        "import 'package:P/l.dart';\n"
        'int fromT() => fromL() + hiddenVal;\n',
      );

    void stageFromSourceProject(Directory projDir, {required bool includeT}) {
      Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
      Directory('${projDir.path}/src/P/lib/src').createSync(recursive: true);
      File(
        '${projDir.path}/pubspec.yaml',
      ).writeAsStringSync('name: analyze_stub\nenvironment:\n  sdk: ^3.7.0\n');
      File('${projDir.path}/src/P/pubspec.yaml')
          .writeAsStringSync('name: P\nenvironment:\n  sdk: ^3.7.0\n');
      Link('${projDir.path}/src/P/lib/l.dart').createSync(realL.path);

      final packages = <Map<String, String>>[
        {
          'name': 'P',
          'rootUri': '../src/P',
          'packageUri': 'lib/',
          'languageVersion': '3.7',
        },
      ];
      final manifestLines = <String>['P/pubspec.yaml', 'P/lib/l.dart'];
      if (includeT) {
        Directory('${projDir.path}/src/Q/lib').createSync(recursive: true);
        File('${projDir.path}/src/Q/pubspec.yaml').writeAsStringSync(
          'name: Q\nenvironment:\n  sdk: ^3.7.0\n'
          'dependencies:\n  P: any\n',
        );
        Link('${projDir.path}/src/Q/lib/t.dart').createSync(realT.path);
        packages.add({
          'name': 'Q',
          'rootUri': '../src/Q',
          'packageUri': 'lib/',
          'languageVersion': '3.7',
        });
        manifestLines.addAll(['Q/pubspec.yaml', 'Q/lib/t.dart']);
      }
      File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
        jsonEncode({'configVersion': 2, 'packages': packages}),
      );
      File('${projDir.path}/.dart_tool/src_manifest.txt')
          .writeAsStringSync('${manifestLines.join('\n')}\n');
    }

    // 1. Analyze L itself across local (with real source tree + stale symlink),
    // sandboxed (only declared inputs), and worker strategy.
    final localLProj = Directory('${realDir.path}/local_L.proj');
    stageFromSourceProject(localLProj, includeT: false);
    // Even if a prior unsandboxed build left a symlink to hidden.dart,
    // `src_manifest.txt` pruning removes it before analysis.
    Link('${localLProj.path}/src/P/lib/src/hidden.dart')
        .createSync(realHidden.path);

    final localLStamp = File('${tmp.path}/local_L.analyzed');
    final localLRes = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      localLProj.path,
      '--stamp',
      localLStamp.path,
      '--fatal-infos',
      '--source',
      'src/P/lib/l.dart',
    ], workingDirectory: realDir.path);

    final sandboxLProj = Directory('${tmp.path}/sandbox_L/L.proj');
    stageFromSourceProject(sandboxLProj, includeT: false);
    final sandboxLStamp = File('${tmp.path}/sandbox_L.analyzed');
    final sandboxLRes = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      sandboxLProj.path,
      '--stamp',
      sandboxLStamp.path,
      '--fatal-infos',
      '--source',
      'src/P/lib/l.dart',
    ], workingDirectory: tmp.path);

    final workerLProj = Directory('${realDir.path}/worker_L.proj');
    stageFromSourceProject(workerLProj, includeT: false);
    Link('${workerLProj.path}/src/P/lib/src/hidden.dart')
        .createSync(realHidden.path);
    final workerLStamp = File('${tmp.path}/worker_L.analyzed');
    final proc = await Process.start(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      '--persistent_worker',
    ], workingDirectory: realDir.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));
    proc.stdin.add(
      _encodeWorkRequest(
        arguments: [
          'analyze',
          '--sdk',
          sdkRoot,
          '--project',
          workerLProj.path,
          '--stamp',
          workerLStamp.path,
          '--fatal-infos',
          '--sdk-summary',
          sdkSummaryPath,
          '--source',
          'src/P/lib/l.dart',
        ],
      ),
    );
    await proc.stdin.flush();
    expect(await responses.moveNext(), isTrue);
    final workerLRes = _decodeWorkResponse(responses.current);

    expect(localLRes.exitCode, isNonZero);
    expect(sandboxLRes.exitCode, isNonZero);
    expect(workerLRes.exitCode, isNonZero);
    expect(localLStamp.existsSync(), isFalse);
    expect(sandboxLStamp.existsSync(), isFalse);
    expect(workerLStamp.existsSync(), isFalse);
    expect(
      '${localLRes.stdout}\n${localLRes.stderr}',
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );
    expect(
      '${sandboxLRes.stdout}\n${sandboxLRes.stderr}',
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );
    expect(
      workerLRes.output,
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );

    // 2. Analyze target T depending on uncovered L across local, sandboxed,
    // and worker strategies.
    final localTProj = Directory('${realDir.path}/local_T.proj');
    stageFromSourceProject(localTProj, includeT: true);
    final localTStamp = File('${tmp.path}/local_T.analyzed');
    final localTRes = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      localTProj.path,
      '--stamp',
      localTStamp.path,
      '--fatal-infos',
      '--source',
      'src/Q/lib/t.dart',
    ], workingDirectory: realDir.path);

    final sandboxTProj = Directory('${tmp.path}/sandbox_T/T.proj');
    stageFromSourceProject(sandboxTProj, includeT: true);
    final sandboxTStamp = File('${tmp.path}/sandbox_T.analyzed');
    final sandboxTRes = Process.runSync(Platform.resolvedExecutable, [
      analyzeRunnerDill,
      '--dart',
      Platform.resolvedExecutable,
      '--project',
      sandboxTProj.path,
      '--stamp',
      sandboxTStamp.path,
      '--fatal-infos',
      '--source',
      'src/Q/lib/t.dart',
    ], workingDirectory: tmp.path);

    final workerTProj = Directory('${realDir.path}/worker_T.proj');
    stageFromSourceProject(workerTProj, includeT: true);
    final workerTStamp = File('${tmp.path}/worker_T.analyzed');
    proc.stdin.add(
      _encodeWorkRequest(
        arguments: [
          'analyze',
          '--sdk',
          sdkRoot,
          '--project',
          workerTProj.path,
          '--stamp',
          workerTStamp.path,
          '--fatal-infos',
          '--sdk-summary',
          sdkSummaryPath,
          '--source',
          'src/Q/lib/t.dart',
        ],
      ),
    );
    await proc.stdin.flush();
    expect(await responses.moveNext(), isTrue);
    final workerTRes = _decodeWorkResponse(responses.current);
    await responses.cancel();
    await proc.stdin.close();

    expect(localTRes.exitCode, isNonZero);
    expect(sandboxTRes.exitCode, isNonZero);
    expect(workerTRes.exitCode, isNonZero);
    expect(localTStamp.existsSync(), isFalse);
    expect(sandboxTStamp.existsSync(), isFalse);
    expect(workerTStamp.existsSync(), isFalse);
    expect(
      '${localTRes.stdout}\n${localTRes.stderr}',
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );
    expect(
      '${sandboxTRes.stdout}\n${sandboxTRes.stderr}',
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );
    expect(
      workerTRes.output,
      contains("Target of URI doesn't exist: 'package:P/src/hidden.dart'"),
    );
  });
}
