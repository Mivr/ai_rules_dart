/// The dependency modules of a debug app with defines compile with its
/// environment.
///
/// `:app_defines_dev_kernel` and `:app_defines_prod_kernel` are the linked
/// `-c dbg` kernels of two apps over `//defines_env`, a library whose
/// constants read a define, a value from a defines file and the flavor. A
/// constant is evaluated where it is compiled, so each value is in a kernel
/// only if `//defines_env`'s module compiled with it (the entry reads the
/// library's outline, which holds the evaluated constants).
library;

import 'dart:convert';
import 'dart:io';

String _runfile(String variable) {
  final rel = Platform.environment[variable];
  final root = Platform.environment['TEST_SRCDIR'];
  if (rel == null || root == null) {
    stderr.writeln('FAIL: $variable or TEST_SRCDIR is unset');
    exit(1);
  }
  return '$root/$rel';
}

/// Whether [needle] occurs in [haystack] as UTF-8 bytes.
bool _contains(List<int> haystack, String needle) {
  final n = utf8.encode(needle);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  var failed = false;
  void expect(String variable, List<String> present, List<String> absent) {
    final bytes = File(_runfile(variable)).readAsBytesSync();
    for (final value in present) {
      if (!_contains(bytes, value)) {
        stderr.writeln('FAIL: $variable lacks $value');
        failed = true;
      }
    }
    for (final value in absent) {
      if (_contains(bytes, value)) {
        stderr.writeln('FAIL: $variable holds $value');
        failed = true;
      }
    }
  }

  expect(
    'APP_DEV_DILL',
    ['DEFCFG_FOO_DEV/DEFCFG_FILE_DEV/defcfgdev'],
    ['DEFCFG_FOO_PROD', 'DEFCFG_FILE_PROD'],
  );
  expect(
    'APP_PROD_DILL',
    ['DEFCFG_FOO_PROD/DEFCFG_FILE_PROD/defcfgprod'],
    ['DEFCFG_FOO_DEV', 'DEFCFG_FILE_DEV'],
  );
  if (failed) exit(1);
  stdout.writeln('PASS');
}
