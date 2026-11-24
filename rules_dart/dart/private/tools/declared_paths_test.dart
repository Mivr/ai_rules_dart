import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../build_runner/runner/declared_paths.dart';

void main() {
  test('a Windows path takes the asset below it with Windows separators', () {
    // The spelling build_runner asks for; `p.join` would leave `lib/src/a.dart`
    // as it is, between a `\` directory and the file name.
    expect(
      declaredPath(
        r'c:\users\runner~1\appdata\local\temp\dart_build_runner\targets\0\packages\app',
        'lib/src/db/database.dart',
        context: p.windows,
      ),
      r'c:\users\runner~1\appdata\local\temp\dart_build_runner\targets\0\packages\app\lib\src\db\database.dart',
    );
    expect(
      p.windows.join(r'c:\a\app', 'lib/src/x.dart'),
      r'c:\a\app\lib/src/x.dart',
      reason: 'the spelling of the old key, which build_runner never asks for',
    );
  });

  test('a POSIX path is the plain join', () {
    expect(
      declaredPath(
        '/tmp/dart_build_runner/targets/0/packages/app',
        'lib/src/db/database.dart',
        context: p.posix,
      ),
      '/tmp/dart_build_runner/targets/0/packages/app/lib/src/db/database.dart',
    );
  });

  test('a file at the package root, and the artifact tree path', () {
    expect(
      declaredPath(r'c:\a\app', 'pubspec.yaml', context: p.windows),
      r'c:\a\app\pubspec.yaml',
    );
    expect(
      declaredPath(
        r'c:\a\app',
        '.dart_tool/build/generated/app/lib/a.g.dart',
        context: p.windows,
      ),
      r'c:\a\app\.dart_tool\build\generated\app\lib\a.g.dart',
    );
  });

  test('the host context is the default', () {
    expect(
      declaredPath(p.join('a', 'app'), 'lib/b.dart'),
      p.join('a', 'app', 'lib', 'b.dart'),
    );
  });
}
