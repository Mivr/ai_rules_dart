// A test that imports its library via a relative `../lib/` URI rather than a
// `package:` URI.
import '../lib/testpkg.dart';

void main() {
  print(testpkgValue());
}
