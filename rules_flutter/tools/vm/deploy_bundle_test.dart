import 'package:test/test.dart';

import 'vm_deploy.dart';

void main() {
  group('parseWindowsSessionId', () {
    test('returns the active auto-logon session', () {
      expect(
        parseWindowsSessionId(
          ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME\n'
          ' testuser              console             1  Active      none   10/25/2026 1:00 PM\n',
        ),
        '1',
      );
    });

    test('is null when nobody is logged on', () {
      expect(parseWindowsSessionId('No User exists for *\n'), isNull);
    });

    test('is null when the session is disconnected', () {
      expect(
        parseWindowsSessionId(
          ' testuser              console             1  Disc        none   10/25/2026 1:00 PM\n',
        ),
        isNull,
      );
    });
  });

  group('parseWindowsExeName', () {
    test('picks the first listing entry, trimmed', () {
      expect(
        parseWindowsExeName('hello_world.exe\r\nflutter_windows.dll\n'),
        'hello_world.exe',
      );
    });

    test('is empty for an empty listing', () {
      expect(parseWindowsExeName('\n'), isEmpty);
    });
  });

  group('buildWindowsVerifyBat', () {
    test('renders the PsExec wrapper exactly', () {
      expect(
        buildWindowsVerifyBat(
          pythonPath: r'C:\Python312',
          appName: 'hello_world',
          exeName: 'hello_world.exe',
          screenshotRemotePath: r'C:\temp\screenshot.png',
          outputRemotePath: r'C:\temp\screenshot_out.txt',
        ),
        'powershell -Command "Set-Content -Path C:\\temp\\run_verify.bat '
        "'C:\\Python312\\python.exe C:\\temp\\verify_scripts\\dxgi_screenshot.py "
        r'C:\temp\hello_world\hello_world.exe C:\temp\screenshot.png 15 '
        "> C:\\temp\\screenshot_out.txt 2>&1' -Force\"",
      );
    });
  });
}
