/// Pins the bytes the three native-executable tools write.
///
/// `android_bundle`, `kernel_filter` and `macho_edit` used to run as kernels
/// under the Dart VM. Each case here runs the built executable on a fixed
/// input and compares its output with the SHA-256 (or exact text) the kernel
/// build wrote for the same input, recorded once and kept verbatim, so a
/// regression from compiling them ahead of time shows as a byte difference.
@Tags(['runfiles'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../sha256.dart';

/// The built executable named by environment variable [name].
String _exe(String name) {
  final String? rlocation = Platform.environment[name];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (rlocation == null || srcdir == null) {
    fail('$name is not set; run this through bazel test');
  }
  return '$srcdir/$rlocation';
}

/// A 4 KiB AArch64 ELF-looking library: header bytes, then a repeating ramp.
Uint8List _fakeLibrary() {
  final bytes = Uint8List.fromList(
    List<int>.generate(4096, (int i) => i % 251),
  );
  bytes.setRange(0, 4, <int>[0x7f, 0x45, 0x4c, 0x46]);
  bytes[4] = 2;
  bytes[5] = 1;
  bytes[18] = 183;
  bytes[19] = 0;
  return bytes;
}

String _hex(String path) => sha256Hex(File(path).readAsBytesSync());

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('native_exe_'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<ProcessResult> run(String exe, List<String> args) =>
      Process.run(exe, args, workingDirectory: work.path);

  test('macho_edit stub and patch write the kernel build bytes', () async {
    final String exe = _exe('MACHO_EDIT');
    final ProcessResult stub = await run(exe, <String>[
      'stub', '--output', 'stub.bin', '--arch', 'arm64', //
      '--platform', 'ios', '--min-os', '15.0', '--sdk-version', '15.0',
      '--install-name', '@rpath/App.framework/App',
    ]);
    expect(stub.exitCode, 0, reason: '${stub.stderr}');
    expect(
      _hex('${work.path}/stub.bin'),
      'ffa7461006cfd424a1c71e542832c9d246b09d210a0a3c1c2e9480374074bf85',
    );
    final ProcessResult patch = await run(exe, <String>[
      'patch', '--input', 'stub.bin', '--output', 'patched.bin', //
      '--platform', 'macos', '--min-os', '12.0', '--sdk-version', '12.0',
      '--install-name', '@rpath/App.framework/Versions/A/App',
      '--strip-symbols',
    ]);
    expect(patch.exitCode, 0, reason: '${patch.stderr}');
    expect(
      _hex('${work.path}/patched.bin'),
      '656703fcf0a02675850a39f6dc43464343f78efd6b7a84908c2efa94f3444dc2',
    );
  });

  test('android_bundle jars match the kernel build bytes', () async {
    final String exe = _exe('ANDROID_BUNDLE');
    File('${work.path}/libapp.so').writeAsBytesSync(_fakeLibrary());
    final ProcessResult empty = await run(exe, <String>[
      'empty-jar', '--output', 'empty.jar', //
    ]);
    expect(empty.exitCode, 0, reason: '${empty.stderr}');
    expect(
      _hex('${work.path}/empty.jar'),
      '8739c76e681f900923b900c9df0ef75cf421d39cabb54650c4b9ad19b6a76d85',
    );
    final ProcessResult libs = await run(exe, <String>[
      'native-libs-jar', '--output', 'libs.jar', '--abi', 'arm64-v8a', //
      '--machine', '183', 'lib/arm64-v8a/libapp.so=libapp.so',
    ]);
    expect(libs.exitCode, 0, reason: '${libs.stderr}');
    expect(
      _hex('${work.path}/libs.jar'),
      'cef9f5502d78bab47069d18ad4ab0350af5479a1da4472717500dfc60ccc9a1f',
    );
  });

  test(
    'kernel_filter shows a compile error exactly as the kernel build',
    () async {
      Directory('${work.path}/w/lib').createSync(recursive: true);
      File('${work.path}/w/lib/main.dart').writeAsStringSync('void main(){}\n');
      File('${work.path}/inputs.manifest').writeAsStringSync(
        'lib/main.dart\n# staged\n# allowed-reads\n# filesystem-roots\n'
        '# entrypoint\n# output\n',
      );
      File('${work.path}/fake.dart').writeAsStringSync(
        'import "dart:io";\n'
        'void main() {\n'
        '  stdout.writeln("result ID");\n'
        '  stdout.writeln("ID");\n'
        '  stdout.writeln("lib/main.dart:3:5: Error: Expected `;` after this.");\n'
        '  stdout.writeln("ID app.dill 1");\n'
        '  stderr.writeln("to stderr");\n'
        '  exit(1);\n'
        '}\n',
      );
      final ProcessResult r = await Process.run(
        _exe('KERNEL_FILTER'),
        <String>[
          '--declared-inputs', '${work.path}/inputs.manifest', '--', //
          Platform.resolvedExecutable, '${work.path}/fake.dart',
        ],
        workingDirectory: '${work.path}/w',
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(r.exitCode, 1);
      expect(
        r.stdout,
        'result ID\nID\nlib/main.dart:3:5: Error: Expected `;` after this.\n'
        'ID app.dill 1\n',
      );
      expect(r.stderr, 'to stderr\n');
    },
  );
}
