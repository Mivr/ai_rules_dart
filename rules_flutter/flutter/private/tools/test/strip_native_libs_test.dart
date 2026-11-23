import 'package:test/test.dart';

import '../strip_native_libs.dart';

void main() {
  group('nativeLibraries', () {
    test('takes every shared object under lib/', () {
      expect(
        nativeLibraries([
          'META-INF/MANIFEST.MF',
          'io/flutter/embedding/engine/FlutterJNI.class',
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libVkLayer_khronos_validation.so',
        ]),
        [
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libVkLayer_khronos_validation.so',
        ],
      );
    });

    test('leaves shared objects outside lib/ alone', () {
      expect(nativeLibraries(['assets/libfoo.so', 'lib/README']), isEmpty);
    });
  });

  test('strips as the Android Gradle Plugin does', () {
    expect(stripArguments(input: 'in.so', output: 'out.so'), [
      '--strip-unneeded',
      '-o',
      'out.so',
      'in.so',
    ]);
  });
}
