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

  test('deletes the undeclared .deps sidecar while keeping the map', () {
    // Drives `runWebCompileRequest` with a stub compiler (a Dart script run
    // through the real `dart` binary) that writes the `<output>.js`,
    // `<output>.js.map` and `<output>.js.deps` sidecars a real `dart compile
    // js` writes. The `.deps` file carries absolute `file:` paths, so it is
    // never a declared output: the runner removes it before it exits while
    // the declared `.js` and `.js.map` stay.
    final projDir = Directory('${tmp.path}/sidecar.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/src/pkg/main.dart')
        .writeAsStringSync('void main() {}\n');
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/main.dart\n');
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'pkg', 'rootUri': '../src/pkg', 'packageUri': 'lib/'},
        ],
      }),
    );

    final stub = File('${tmp.path}/stub_compiler.dart')
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> args) {\n'
        '  final out = args[args.indexOf("-o") + 1];\n'
        "  File(out).writeAsStringSync('js');\n"
        "  File('\$out.map').writeAsStringSync('map');\n"
        "  File('\$out.deps').writeAsStringSync('deps');\n"
        '}\n',
      );
    final outJs = File('${tmp.path}/sidecar.js');
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=sidecar.proj',
        stub.path,
        '-o',
        outJs.path,
        'sidecar.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, 0, reason: '$outBuf\n$errBuf');
    expect(outJs.existsSync(), isTrue, reason: 'the declared .js stays');
    expect(
      File('${outJs.path}.map').existsSync(),
      isTrue,
      reason: 'the declared .js.map stays',
    );
    expect(
      File('${outJs.path}.deps').existsSync(),
      isFalse,
      reason: 'the undeclared .deps sidecar is removed before exit',
    );
  });

  test('a sidecar that cannot be removed fails loudly', () {
    // Drives `runWebCompileRequest` with a stub compiler that leaves an
    // undeletable `<output>.js.deps` behind (a non-empty directory, which
    // `deleteSync` refuses). The runner must fail with a message naming the
    // path, never let the stray file survive silently.
    final projDir = Directory('${tmp.path}/stuck.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/src/pkg/main.dart')
        .writeAsStringSync('void main() {}\n');
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/main.dart\n');
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'pkg', 'rootUri': '../src/pkg', 'packageUri': 'lib/'},
        ],
      }),
    );

    final stub = File('${tmp.path}/stuck_compiler.dart')
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> args) {\n'
        '  final out = args[args.indexOf("-o") + 1];\n'
        "  File(out).writeAsStringSync('js');\n"
        "  File('\$out.map').writeAsStringSync('map');\n"
        "  Directory('\$out.deps').createSync();\n"
        "  File('\$out.deps/stale.txt').writeAsStringSync('stale');\n"
        '}\n',
      );
    final outJs = File('${tmp.path}/stuck.js');
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=stuck.proj',
        stub.path,
        '-o',
        outJs.path,
        'stuck.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero, reason: '$outBuf\n$errBuf');
    expect(
      errBuf.toString(),
      contains('${outJs.path}.deps'),
      reason: 'the message names the leftover sidecar',
    );
    expect(
      Directory('${outJs.path}.deps').existsSync(),
      isTrue,
      reason: 'the leftover sidecar is reported, not hidden',
    );
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

  test('refuses a staged source with a file: import before compiling', () {
    final projDir = Directory('${tmp.path}/file_app.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);

    File('${projDir.path}/src/pkg/main.dart').writeAsStringSync(
      "import 'file:///proc/self/cwd/pkg/lib/secret.dart';\n"
      'void main() => print(secretValue);\n',
    );
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/main.dart\n');

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=file_app.proj',
        'compile',
        'js',
        '-o',
        '${tmp.path}/file_app.js',
        'org-dartlang-root:///file_app.proj/src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero);
    expect(
      errBuf.toString(),
      contains(
        "import 'file:///proc/self/cwd/pkg/lib/secret.dart' "
        'is not a declared input',
      ),
    );
    expect(File('${tmp.path}/file_app.js').existsSync(), isFalse);
  });

  test('refuses triple-quoted directive URIs before compiling', () {
    // The compile is rooted at the staged project (the argv shape
    // `dart_web_application.bzl` emits): the multi-root names the `.proj`
    // directory, and the package config and entrypoint are addressed under it.
    final projDir = Directory('${tmp.path}/tq_app.proj');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);

    File('${projDir.path}/src/pkg/main.dart').writeAsStringSync(
      "import '''   \n/secret/s.dart''';\n"
      'void main() => print(hostSecret);\n',
    );
    File('${projDir.path}/src/pkg/evil_export.dart')
        .writeAsStringSync("export r'''\t\n/secret/s.dart''';\n");
    File('${projDir.path}/src/pkg/missing.dart')
        .writeAsStringSync("import 'nosuch.dart';\n");
    File('${projDir.path}/.dart_tool/src_manifest.txt').writeAsStringSync(
      'pkg/main.dart\npkg/evil_export.dart\npkg/missing.dart\n',
    );

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final code = runWebCompileRequest(
      [
        '--dart=${Platform.resolvedExecutable}',
        '--project=tq_app.proj',
        'compile',
        'js',
        '--multi-root-scheme=org-dartlang-root',
        '--multi-root=tq_app.proj/',
        '--packages=org-dartlang-root:///.dart_tool/package_config.json',
        '-o',
        '${tmp.path}/tq_app.js',
        'org-dartlang-root:///src/pkg/main.dart',
      ],
      outSink: outBuf,
      errSink: errBuf,
      workingDirectory: tmp.path,
    );
    expect(code, isNonZero);
    expect(
      errBuf.toString(),
      contains("import '   \n/secret/s.dart' is not a declared input"),
    );
    expect(
      errBuf.toString(),
      contains("export '\t\n/secret/s.dart' is not a declared input"),
    );
    expect(
      errBuf.toString(),
      contains("import 'nosuch.dart' is not a declared input"),
    );
    expect(File('${tmp.path}/tq_app.js').existsSync(), isFalse);
  });

  test('an unreadable package config skips the extpkgs prune', () {
    // Drives `_referencedExtPackages` with configs it cannot use: malformed
    // JSON (`FormatException`) and a config path that cannot be read
    // (`FileSystemException`). Both read as no referenced packages, so the
    // extpkgs prune is skipped while `src/` orphans are still pruned.
    for (final config in ['{oops', null]) {
      final tag = config == null ? 'unreadable' : 'malformed';
      final projDir = Directory('${tmp.path}/${tag}_app.proj');
      final extDir = Directory('${tmp.path}/${tag}_app.extpkgs');
      Directory('${projDir.path}/src/pkg').createSync(recursive: true);
      Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
      Directory('${extDir.path}/orphan_pkg/lib').createSync(recursive: true);
      File('${projDir.path}/src/pkg/pubspec.yaml')
          .writeAsStringSync('name: pkg\n');
      File('${projDir.path}/src/pkg/main.dart')
          .writeAsStringSync('void main() {}\n');
      File('${projDir.path}/src/pkg/orphan.dart')
          .writeAsStringSync('void orphan() {}\n');
      File('${extDir.path}/orphan_pkg/lib/o.dart')
          .writeAsStringSync('void o() {}\n');
      File('${projDir.path}/.dart_tool/src_manifest.txt')
          .writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\n');
      if (config == null) {
        Directory('${projDir.path}/.dart_tool/package_config.json')
            .createSync();
      } else {
        File('${projDir.path}/.dart_tool/package_config.json')
            .writeAsStringSync(config);
      }

      final allowed = pruneOrphanedStagedFiles(projDir.path);
      expect(allowed, contains('pkg/main.dart'));
      expect(
        File('${projDir.path}/src/pkg/orphan.dart').existsSync(),
        isFalse,
        reason: '$tag config still prunes unlisted src files',
      );
      expect(
        File('${extDir.path}/orphan_pkg/lib/o.dart').existsSync(),
        isTrue,
        reason:
            '$tag config names no referenced packages, so nothing '
            'is pruned from extpkgs',
      );
    }
  });

  test('a valid package config prunes unreferenced extpkgs', () {
    final projDir = Directory('${tmp.path}/valid_app.proj');
    final extDir = Directory('${tmp.path}/valid_app.extpkgs');
    Directory('${projDir.path}/src/pkg').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    Directory('${extDir.path}/kept_pkg/lib').createSync(recursive: true);
    Directory('${extDir.path}/orphan_pkg/lib').createSync(recursive: true);
    File('${projDir.path}/src/pkg/pubspec.yaml')
        .writeAsStringSync('name: pkg\n');
    File('${projDir.path}/src/pkg/main.dart')
        .writeAsStringSync('void main() {}\n');
    File('${extDir.path}/kept_pkg/lib/k.dart')
        .writeAsStringSync('void k() {}\n');
    File('${extDir.path}/orphan_pkg/lib/o.dart')
        .writeAsStringSync('void o() {}\n');
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/pubspec.yaml\npkg/main.dart\n');
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'pkg', 'rootUri': '../src/pkg', 'packageUri': 'lib/'},
          {
            'name': 'kept_pkg',
            'rootUri': '../../valid_app.extpkgs/kept_pkg',
            'packageUri': 'lib/',
          },
        ],
      }),
    );

    pruneOrphanedStagedFiles(projDir.path);
    expect(File('${extDir.path}/kept_pkg/lib/k.dart').existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(
        '${extDir.path}/orphan_pkg',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
  });
}
