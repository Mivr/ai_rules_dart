import 'package:test/test.dart';

import 'package_uri_probe.dart';

void main() {
  test(
    'package: URIs resolve to the files staged in runfiles',
    probePackageUris,
  );
}
