import 'package:test/test.dart';

import 'package_uri_probe.dart';

void main() {
  test('package: URIs resolve to the files staged in runfiles', () async {
    final Uri resolved = await probePackageUris();
    expect(resolved.scheme, 'file');
    expect(resolved.path, endsWith('/lib/data/sample.txt'));
  });
}
