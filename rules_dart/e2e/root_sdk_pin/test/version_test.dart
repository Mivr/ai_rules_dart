import 'dart:io';

void main() {
  if (!Platform.version.contains('3.13.5')) {
    stderr.writeln('Expected Dart 3.13.5, got: ${Platform.version}');
    exit(1);
  }
}
