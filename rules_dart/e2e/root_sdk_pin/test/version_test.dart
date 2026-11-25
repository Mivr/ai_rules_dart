import 'dart:io';

void main() {
  if (!Platform.version.contains('3.14.0')) {
    stderr.writeln('Expected Dart 3.14.0, got: ${Platform.version}');
    exit(1);
  }
}
