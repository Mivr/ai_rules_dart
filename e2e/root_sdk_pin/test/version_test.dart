import 'dart:io';

void main() {
  if (!Platform.version.contains('3.12.2')) {
    stderr.writeln('Expected Dart 3.12.2, got: ${Platform.version}');
    exit(1);
  }
}
