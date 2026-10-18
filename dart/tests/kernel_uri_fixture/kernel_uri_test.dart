// Behavioural proof that a compiled `dart_binary` does not depend on where it
// was built, and that its constants are the ones `dart compile exe` folds.
//
// Given a source path, `dart compile` names an entrypoint outside any package
// `file:///<absolute path>` — the sandbox directory, the output base — and the
// binary keeps that URI in its stack traces and in the private-name suffixes
// derived from it, so every rebuild elsewhere changes its bytes. The compile
// reads sources through a filesystem rooted at the exec root instead, so the
// URI is the same wherever the action runs.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _entrypoint =
    'org-dartlang-root:///dart/tests/kernel_uri_fixture/bin/probe.dart';

String _lineWithPrefix(String output, String prefix) {
  for (final line in output.split('\n')) {
    if (line.startsWith(prefix)) return line;
  }
  throw StateError('missing `$prefix` line in output:\n$output');
}

void main() {
  final runfiles = Runfiles.create();
  for (final name in ['probe', 'probe_with_asset']) {
    final exe = runfiles.rlocation(
      '_main/dart/tests/kernel_uri_fixture/$name${Platform.isWindows ? '.exe' : ''}',
    );
    final result = Process.runSync(exe, []);
    if (result.exitCode != 0) {
      throw StateError('$name exited ${result.exitCode}: ${result.stderr}');
    }
    final out = result.stdout as String;
    if (!out.contains('product=true')) {
      throw StateError(
        '$name: an exe must see `dart.vm.product` true, as one built by '
        '`dart compile exe` from source does. Output:\n$out',
      );
    }
    final frameLine = _lineWithPrefix(out, 'frame=');
    if (!frameLine.contains('($_entrypoint:') ||
        frameLine.contains('file://') ||
        frameLine.contains('org-dartlang-bazel')) {
      throw StateError(
        '$name: the entrypoint must be named $_entrypoint, not by a path '
        'that depends on where it was built. Output:\n$out',
      );
    }
  }

  for (final name in [
    'probe_kernel',
    'probe_kernel_whole',
    'probe_kernel_with_asset',
  ]) {
    final dill = runfiles.rlocation(
      '_main/dart/tests/kernel_uri_fixture/$name.dill',
    );
    final result = Process.runSync(Platform.resolvedExecutable, [dill]);
    if (result.exitCode != 0) {
      throw StateError('$name exited ${result.exitCode}: ${result.stderr}');
    }
    final out = result.stdout as String;
    if (!out.contains('product=true')) {
      throw StateError(
        '$name: a kernel binary must see `dart.vm.product` true, matching '
        '`dart compile kernel`. Output:\n$out',
      );
    }
    final scriptLine = _lineWithPrefix(out, 'script=').trim();
    final scriptUri = Uri.parse(scriptLine.substring('script='.length));
    if (scriptUri.scheme != 'file' || !scriptUri.path.endsWith('/$name.dill')) {
      throw StateError(
        '$name: expected Platform.script to be a file: URI ending in '
        '/$name.dill, got $scriptLine',
      );
    }
    final frameLine = _lineWithPrefix(out, 'frame=');
    if (!frameLine.contains('($_entrypoint:') ||
        frameLine.contains('file://') ||
        frameLine.contains('org-dartlang-bazel')) {
      throw StateError(
        '$name: the entrypoint must be named $_entrypoint, not by a path '
        'that depends on where it was built. Output:\n$out',
      );
    }
  }

  // The test itself goes through the same front end.
  if (!const bool.fromEnvironment('dart.vm.product')) {
    throw StateError('dart_test must compile with `dart.vm.product` true');
  }
  if (Platform.script.scheme != 'file' ||
      !Platform.script.path.endsWith('.dill')) {
    throw StateError(
      'dart_test expected file: .dill Platform.script, got ${Platform.script}',
    );
  }
  final frame = StackTrace.current.toString().split('\n').first;
  if (!frame.contains(
        'org-dartlang-root:///dart/tests/kernel_uri_fixture/kernel_uri_test.dart',
      ) ||
      frame.contains('file://') ||
      frame.contains('org-dartlang-bazel')) {
    throw StateError('dart_test named its entrypoint by a build path: $frame');
  }
  print('entrypoint URIs are build-location independent');
}
