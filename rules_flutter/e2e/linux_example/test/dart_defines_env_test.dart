/// A `dart_test` with `defines` compiles its dependency modules with them.
///
/// `defcfgFoo` is a constant of `//defines_env`, evaluated where that library's
/// module compiled, so it holds the test's define only if the module took it.
library;

import 'dart:io';

import 'package:defines_env/defines_env.dart';

void main() {
  if (defcfgSummary != 'DEFCFG_FOO_DART_TEST/unset/unset') {
    stderr.writeln('FAIL: //defines_env compiled with "$defcfgSummary"');
    exit(1);
  }
  stdout.writeln('PASS');
}
