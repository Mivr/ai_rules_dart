import 'package:fmtpkg/fmtpkg.dart';

void main() {
  // Same assertions as host_config_test, against the probe's helper-fetched
  // package: the hostile template must neither expand `$Format:%H$` nor
  // rewrite newlines on the way to the compiler.
  if (version.length != 11) {
    throw StateError(
      'host template rewrote the git package: '
      'version.length is ${version.length}, expected 11 '
      '(unexpanded \$Format:%H%)',
    );
  }
  if (text != 'line1\nline2') {
    throw StateError(
      'host template rewrote the git package: '
      'multi-line string is ${text.length} characters, expected 11 '
      '(LF endings)',
    );
  }
}
