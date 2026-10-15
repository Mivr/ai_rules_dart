import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Asserts `dart_wasm_binary` keeps everything needed to run the module: the
/// `.mjs` loader (also reachable alone through the `mjs` output group), the
/// `.support.js` feature check, and the source map.
void main(List<String> args) {
  final r = Runfiles.create();

  File output(String path) {
    final file = File(r.rlocation(path));
    if (!file.existsSync()) {
      throw StateError('$path is not an output of app_wasm');
    }
    return file;
  }

  output('_main/app_wasm.wasm');
  output('_main/app_wasm.support.js');
  output('_main/app_wasm.wasm.map');
  final mjs = output('_main/app_wasm.mjs').readAsStringSync();
  if (!mjs.contains('instantiate')) {
    throw StateError('app_wasm.mjs is not the module loader');
  }
  if (args.single != '_main/app_wasm.mjs') {
    throw StateError('mjs output group gave ${args.single}');
  }
  stdout.writeln('PASS');
}
