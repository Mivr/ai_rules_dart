// The AOT `kernel_link` and `analyzer_summary` write the same bytes as the
// kernel (`.dill`) forms they replaced, for the same inputs.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _prefix = 'org-dartlang-root:///';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final String aotSummary = runfiles.rlocation(args[0]);
  final String kernelSummary = runfiles.rlocation(args[1]);
  final String aotLink = runfiles.rlocation(args[2]);
  final String kernelLink = runfiles.rlocation(args[3]);
  final String sdkSummaryPath = runfiles.rlocation(args[4]);
  final String kernelModule = runfiles.rlocation(args[5]);
  final String sdkDir = p.dirname(p.dirname(Platform.resolvedExecutable));
  final exe = Platform.isWindows ? '.exe' : '';
  final String dart = Platform.resolvedExecutable;
  final String aotRuntime = p.join(sdkDir, 'bin', 'dartaotruntime$exe');

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aot_parity_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('analyzer_summary summarize output equals the kernel form', () {
    File(p.join(tmp.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('int a() => 1;\nclass A { final int x = 2; }\n');
    final packages = File(p.join(tmp.path, 'package_config.json'))
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'pa', 'rootUri': tmp.uri.toString(), 'packageUri': 'lib/'},
          ],
        }),
      );
    String summarize(String runtime, List<String> tool, String out) {
      final ProcessResult res = Process.runSync(runtime, [
        ...tool,
        'summarize',
        '--sdk',
        sdkDir,
        '--sdk-summary',
        sdkSummaryPath,
        '--packages',
        packages.path,
        '--source',
        p.join(tmp.path, 'lib', 'a.dart'),
        '--uri',
        'package:pa/a.dart',
        '--out',
        out,
      ]);
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
      return out;
    }

    final String aotOut = summarize(aotRuntime, [
      aotSummary,
    ], p.join(tmp.path, 'aot.sum'));
    final String kernelOut = summarize(dart, [
      kernelSummary,
    ], p.join(tmp.path, 'dill.sum'));
    final List<int> aotBytes = File(aotOut).readAsBytesSync();
    expect(aotBytes, isNotEmpty);
    expect(aotBytes, File(kernelOut).readAsBytesSync());
  });

  test('kernel_link output equals the kernel form', () {
    final String librariesJson = p.join(sdkDir, 'lib', 'libraries.json');
    void write(String rel, String text) {
      File(p.join(tmp.path, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    write(
      'package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'pkg_a', 'rootUri': '${_prefix}pkg_a', 'packageUri': 'lib/'},
        ],
      }),
    );
    write('pkg_a/lib/a.dart', "String a() => 'a';\n");
    write(
      'main.dart',
      "import 'package:pkg_a/a.dart';\nvoid main() { print(a()); }\n",
    );
    void module(String name, String source, {List<String> inputs = const []}) {
      final ProcessResult res = Process.runSync(aotRuntime, [
        kernelModule,
        '--dartaotruntime',
        aotRuntime,
        '--kernel-worker',
        p.join(sdkDir, 'bin', 'snapshots', 'kernel_worker_aot.dart.snapshot'),
        '--target',
        'vm',
        '--dart-sdk-summary',
        p.join(sdkDir, 'lib', '_internal', 'vm_platform_strong.dill'),
        '--packages-file',
        p.join(tmp.path, 'package_config.json'),
        '--libraries-json',
        librariesJson,
        '--multi-root',
        tmp.path,
        '--multi-root-scheme',
        'org-dartlang-root',
        '--no-summary-only',
        '--exclude-non-sources',
        for (final i in inputs) ...['--input-kmod', i],
        '--source',
        source,
        '--output',
        p.join(tmp.path, 'out', '$name.kmod'),
        if (inputs.isEmpty) ...[
          '--output-outline',
          p.join(tmp.path, 'out', '$name.koutline'),
        ],
        '--excluded-output',
        p.join(tmp.path, 'out', '$name.vm_excluded.txt'),
        if (inputs.isNotEmpty) ...[
          '--no-drop',
          '--closure-excluded',
          p.join(tmp.path, 'out', 'a.vm_excluded.txt'),
        ],
      ]);
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    }

    module('a', 'package:pkg_a/a.dart');
    module(
      'entry',
      '${_prefix}main.dart',
      inputs: [p.join(tmp.path, 'out', 'a.koutline')],
    );
    String link(String runtime, String tool, String out) {
      final ProcessResult res = Process.runSync(runtime, [
        tool,
        out,
        p.join(tmp.path, 'out', 'entry.kmod'),
        p.join(tmp.path, 'out', 'a.kmod'),
      ]);
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
      return out;
    }

    final String aotOut = link(
      aotRuntime,
      aotLink,
      p.join(tmp.path, 'aot.dill'),
    );
    final String kernelOut = link(
      dart,
      kernelLink,
      p.join(tmp.path, 'kernel.dill'),
    );
    final List<int> aotBytes = File(aotOut).readAsBytesSync();
    expect(aotBytes, isNotEmpty);
    expect(aotBytes, File(kernelOut).readAsBytesSync());
  });
}
