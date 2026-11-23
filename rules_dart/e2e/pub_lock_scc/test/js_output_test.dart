import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Asserts the compiled JS actually runs the merged cycle: both member
/// packages compiled into the bundle it executes.
void main() {
  final r = Runfiles.create();
  final js = File(r.rlocation('_main/web_app.js')).readAsStringSync();

  const marker = 'dio web adapter ready: true';
  if (!js.contains(marker)) {
    throw StateError(
      'web_app.js is missing "$marker": the merged cycle '
      'must compile into the bundle',
    );
  }
  stdout.writeln('PASS');
}
