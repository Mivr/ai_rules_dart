/// Reads the app's `flutter_assets/` tree (a data dependency) for what the
/// Flutter tool's asset code put there.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late Directory bundle;

  setUpAll(() {
    bundle = Directory(Runfiles.create().rlocation('_main/app_flutter_assets'));
  });

  test('a packages/<name>/ directory is read from that package\'s lib/', () {
    expect(
      File(
        '${bundle.path}/packages/licensed/images/note.txt',
      ).readAsStringSync(),
      'An image the app names through packages/licensed/images/.\n',
    );
  });

  test("a dependency's additional licence is in NOTICES", () {
    final String notices = utf8.decode(
      gzip.decode(File('${bundle.path}/NOTICES.Z').readAsBytesSync()),
    );
    expect(notices, contains('The additional licence of package licensed.'));
  });
}
