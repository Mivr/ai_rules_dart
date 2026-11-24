// Calls into the three packages' code assets and shows, and prints, what
// they returned: `build_hooks: sqlite=<version> add=5 times=42 factors=<json>`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_add/native_add.dart';
import 'package:native_link/native_link.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final line = await summary();
  // The line the e2e checks read, from the Linux runner's stdout and from
  // the Android logcat.
  // ignore: avoid_print
  print(line);
  runApp(MaterialApp(home: Scaffold(body: Center(child: Text(line)))));
}

/// What each package's native code returned, and the link hook's data asset.
Future<String> summary() async {
  String factors;
  try {
    // native_link's link hook writes it in a release or profile build only.
    factors = await rootBundle.loadString('packages/native_link/factors.json');
  } on Object {
    factors = 'none';
  }
  return 'build_hooks: sqlite=${sqlite3.version.libVersion} '
      'add=${add(2, 3)} times=${const Factor(6).times(7)} factors=$factors';
}
