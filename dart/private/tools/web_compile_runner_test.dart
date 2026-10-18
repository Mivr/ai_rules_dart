import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'web_compile_runner.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('web_compile_runner_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('prunes orphaned symlinks in <name>.proj/src and <name>.extpkgs before dart compile js', () {
    final realDir = Directory('${tmp.path}/real')..createSync(recursive: true);
    final realMain = File('${realDir.path}/main.dart')
      ..writeAsStringSync(
        "import 'helper.dart';\n"
        "import 'package:ext_pkg/ext.dart';\n"
        "void main() => print('\$greeting \$extValue');\n",
      );
    final realHelper = File('${realDir.path}/helper.dart')
      ..writeAsStringSync("const String greeting = 'hello';\n");
    final realExt = File('${realDir.path}/ext.dart')
      ..writeAsStringSync("const int extValue = 42;\n");
    final realOrphanExt = File('${realDir.path}/orphan_ext.dart')
      ..writeAsStringSync("const int orphanExt = 99;\n");

    final projDir = Directory('${tmp.path}/app.proj');
    final extDir = Directory('${tmp.path}/app.extpkgs');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    Directory('${extDir.path}/ext_pkg/lib').createSync(recursive: true);

    File(
      '${projDir.path}/src/pkg/pubspec.yaml',
    ).writeAsStringSync('name: pkg\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n');
    Link('${projDir.path}/src/pkg/main.dart').createSync(realMain.path);
    Link('${projDir.path}/src/pkg/helper.dart').createSync(realHelper.path);
    Link('${extDir.path}/ext_pkg/lib/ext.dart').createSync(realExt.path);
    Link('${extDir.path}/ext_pkg/lib/orphan_ext.dart')
        .createSync(realOrphanExt.path);

    final pkgConfig = File('${projDir.path}/.dart_tool/package_config.json')
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'pkg', 'rootUri': '../src/pkg', 'packageUri': 'lib/'},
            {
              'name': 'ext_pkg',
              'rootUri': '../../app.extpkgs/ext_pkg',
              'packageUri': 'lib/',
            },
          ],
        }),
      );

    // Build 1: helper.dart and ext.dart are in manifests; orphan_ext.dart is not.
    File(
      '${projDir.path}/.dart_tool/src_manifest.txt',
    ).writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\npkg/helper.dart\n');
    File('${projDir.path}/.dart_tool/extpkgs_manifest.txt')
        .writeAsStringSync('ext_pkg/lib/ext.dart\n');

    final outJs = File('${tmp.path}/app.js');
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();

    var code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=app.proj',
        'compile',
        'js',
        '--multi-root-scheme=org-dartlang-root',
        '--multi-root=.',
        '--packages=org-dartlang-root:///app.proj/.dart_tool/package_config.json',
        '-o',
        outJs.path,
        'org-dartlang-root:///app.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, 0, reason: '$outBuf\n$errBuf');
    expect(outJs.existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(
        '${extDir.path}/ext_pkg/lib/orphan_ext.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    // Build 2 (incremental local): helper.dart is removed from srcs (and thus
    // from src_manifest.txt), but its symlink remains on disk in app.proj/src/pkg/.
    // Compilation must prune the orphaned symlink and fail just like a clean build.
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\n');
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/pkg/helper.dart',
        followLinks: false,
      ),
      FileSystemEntityType.link,
    );

    outBuf.clear();
    errBuf.clear();
    code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=app.proj',
        'compile',
        'js',
        '--multi-root-scheme=org-dartlang-root',
        '--multi-root=.',
        '--packages=org-dartlang-root:///app.proj/.dart_tool/package_config.json',
        '-o',
        outJs.path,
        'org-dartlang-root:///app.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero);
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/pkg/helper.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
    expect(outJs.existsSync(), isFalse);
    expect(pkgConfig.existsSync(), isTrue);

    // Build 3 (incremental local): restore helper.dart to src_manifest.txt,
    // but remove ext.dart from extpkgs_manifest.txt while leaving its symlink
    // on disk in app.extpkgs/ext_pkg/lib/ext.dart.
    Link('${projDir.path}/src/pkg/helper.dart').createSync(realHelper.path);
    File(
      '${projDir.path}/.dart_tool/src_manifest.txt',
    ).writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\npkg/helper.dart\n');
    File('${projDir.path}/.dart_tool/extpkgs_manifest.txt')
        .writeAsStringSync('');
    expect(
      FileSystemEntity.typeSync(
        '${extDir.path}/ext_pkg/lib/ext.dart',
        followLinks: false,
      ),
      FileSystemEntityType.link,
    );

    outBuf.clear();
    errBuf.clear();
    code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=app.proj',
        'compile',
        'js',
        '--multi-root-scheme=org-dartlang-root',
        '--multi-root=.',
        '--packages=org-dartlang-root:///app.proj/.dart_tool/package_config.json',
        '-o',
        outJs.path,
        'org-dartlang-root:///app.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero);
    expect(
      FileSystemEntity.typeSync(
        '${extDir.path}/ext_pkg/lib/ext.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
    expect(outJs.existsSync(), isFalse);
  });

  test('never prunes without a manifest or when manifest is wildcard *', () {
    final projDir = Directory('${tmp.path}/nomani.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    final f = File('${projDir.path}/src/pkg/a.dart')
      ..writeAsStringSync('void main() {}\n');

    expect(pruneOrphanedStagedFiles(projDir.path), isNull);
    expect(f.existsSync(), isTrue);

    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('*\n');
    expect(pruneOrphanedStagedFiles(projDir.path), isNull);
    expect(f.existsSync(), isTrue);
  });

  test('prunes orphaned symlinks before dart compile wasm', () {
    final realDir = Directory('${tmp.path}/real_wasm')
      ..createSync(recursive: true);
    final realMain = File('${realDir.path}/main.dart')
      ..writeAsStringSync(
        "import 'helper.dart';\n"
        "void main() => print(greeting);\n",
      );
    final realHelper = File('${realDir.path}/helper.dart')
      ..writeAsStringSync("const String greeting = 'wasm';\n");

    final projDir = Directory('${tmp.path}/wasm_app.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);

    File(
      '${projDir.path}/src/pkg/pubspec.yaml',
    ).writeAsStringSync('name: pkg\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n');
    Link('${projDir.path}/src/pkg/main.dart').createSync(realMain.path);
    Link('${projDir.path}/src/pkg/helper.dart').createSync(realHelper.path);

    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'pkg', 'rootUri': '../src/pkg', 'packageUri': 'lib/'},
        ],
      }),
    );

    // Simulate incremental local build where helper.dart was removed from srcs
    // (and thus from src_manifest.txt), leaving its symlink in wasm_app.proj/src/pkg/.
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\n');
    File('${projDir.path}/.dart_tool/extpkgs_manifest.txt')
        .writeAsStringSync('');

    final outWasm = File('${tmp.path}/wasm_app.wasm');
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=wasm_app.proj',
        'compile',
        'wasm',
        '-E--multi-root-scheme=org-dartlang-root',
        '-E--multi-root=.',
        '--packages=org-dartlang-root:///wasm_app.proj/.dart_tool/package_config.json',
        '-o',
        outWasm.path,
        'org-dartlang-root:///wasm_app.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero);
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/pkg/helper.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
    expect(outWasm.existsSync(), isFalse);
  });
}
