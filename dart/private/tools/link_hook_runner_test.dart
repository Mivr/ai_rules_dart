import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'link_hook_runner.dart' as runner;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('link_hook_runner_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('stageWorkspace co-locates declared sources and generated files while excluding untracked workspace files', () {
    // Simulate a workspace root with a hand-written source, a hook, and an
    // untracked shadowing `.g.dart` file.
    final workspace = Directory('${tmp.path}/workspace')
      ..createSync(recursive: true);
    final wsSrc = File('${workspace.path}/lib/src.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync("import 'src.g.dart';\nString get v => generated;\n");
    File('${workspace.path}/lib/src.g.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "const String generated = 'SHADOWED-BY-WORKSPACE';\n",
      );
    final wsHook = File('${workspace.path}/hook/link.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');

    // Simulate bazel-out with the declared generated `.g.dart` file and the
    // `.pkg_roots` staging tree (plus a stale leftover file in `.pkg_roots`
    // from an earlier build that is not in `.manifest`).
    final binDir = Directory('${tmp.path}/bazel-out/bin')
      ..createSync(recursive: true);
    final genSrc = File('${binDir.path}/lib/src.g.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync("const String generated = 'from-gen';\n");

    final pkgRoots = Directory('${binDir.path}/linked.pkg_roots')
      ..createSync(recursive: true);
    final pkgDir = Directory('${pkgRoots.path}/repro')
      ..createSync(recursive: true);
    final stagedSrc = File('${pkgDir.path}/lib/src.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(wsSrc.readAsStringSync());
    final stagedGen = File('${pkgDir.path}/lib/src.g.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(genSrc.readAsStringSync());
    final stagedHook = File('${pkgDir.path}/hook/link.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(wsHook.readAsStringSync());
    File('${pkgDir.path}/lib/stale.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('// leftover from prior build\n');

    File('${pkgRoots.path}/.manifest').writeAsStringSync(
      [
        'file\trepro/lib/src.dart\t${stagedSrc.path}',
        'file\trepro/lib/src.g.dart\t${stagedGen.path}',
        'file\trepro/hook/link.dart\t${stagedHook.path}',
      ].join('\n'),
    );

    final packageConfig = File('${binDir.path}/linked.package_config.json')
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'repro',
              'rootUri': 'linked.pkg_roots/repro',
              'packageUri': 'lib/',
            },
          ],
        }),
      );

    final scratch = Directory('${tmp.path}/scratch')
      ..createSync(recursive: true);
    final staged = runner.stageWorkspace(
      packages: packageConfig,
      packageRoot: pkgDir,
      hook: stagedHook,
      scratch: scratch,
    );

    expect(staged.packageRoot.path, startsWith(scratch.path));
    expect(staged.hook.path, '${staged.packageRoot.path}/hook/link.dart');
    expect(
      File('${staged.packageRoot.path}/lib/src.dart').readAsStringSync(),
      contains("import 'src.g.dart';"),
    );
    expect(
      File('${staged.packageRoot.path}/lib/src.g.dart').readAsStringSync(),
      "const String generated = 'from-gen';\n",
    );
    expect(
      File('${staged.packageRoot.path}/lib/stale.dart').existsSync(),
      isFalse,
    );
  });

  test('stageWorkspace copies pre-assembled dir entries from manifest', () {
    final binDir = Directory('${tmp.path}/bazel-out/bin')
      ..createSync(recursive: true);
    final preAssembled = Directory('${binDir.path}/dep_set')
      ..createSync(recursive: true);
    File('${preAssembled.path}/lib/dep.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('const int dep = 1;\n');

    final pkgRoots = Directory('${binDir.path}/linked.pkg_roots')
      ..createSync(recursive: true);
    final pkgDir = Directory('${pkgRoots.path}/my__pkg')
      ..createSync(recursive: true);
    final stagedHook = File('${pkgDir.path}/hook/link.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');

    File('${pkgRoots.path}/.manifest').writeAsStringSync(
      [
        'dir\tdep\t${preAssembled.path}',
        'file\tmy__pkg/hook/link.dart\t${stagedHook.path}',
      ].join('\n'),
    );

    final packageConfig = File('${binDir.path}/linked.package_config.json')
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
    final scratch = Directory('${tmp.path}/scratch')
      ..createSync(recursive: true);

    runner.stageWorkspace(
      packages: packageConfig,
      packageRoot: pkgDir,
      hook: stagedHook,
      scratch: scratch,
    );

    expect(
      File('${scratch.path}/linked.pkg_roots/dep/lib/dep.dart')
          .readAsStringSync(),
      'const int dep = 1;\n',
    );
  });
}
