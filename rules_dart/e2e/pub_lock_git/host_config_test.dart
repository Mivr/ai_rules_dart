import 'package:fmtpkg/fmtpkg.dart';

void main() {
  // '$Format:%H$' must reach the compiler unexpanded: a host git
  // configuration adding `export-subst` through core.attributesFile would
  // expand it to the 40-hex commit id.
  if (version.length != 11) {
    throw StateError(
      'host git configuration rewrote the git package: '
      'version.length is ${version.length}, expected 11 '
      '(unexpanded \$Format:%H%)',
    );
  }
  // Newlines must stay LF: a host core.autocrlf=true (the Git for Windows
  // default) would rewrite them to CRLF.
  if (text != 'line1\nline2') {
    throw StateError(
      'host git configuration rewrote the git package: '
      'multi-line string is ${text.length} characters, expected 11 '
      '(LF endings)',
    );
  }
}
