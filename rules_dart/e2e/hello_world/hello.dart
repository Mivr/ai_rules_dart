import 'dart:io';

void main(List<String> args) {
  // `stdout.writeln` rather than `print`, which `avoid_print` rejects.
  stdout.writeln('Hello, World!');
  if (args.isNotEmpty) {
    stdout.writeln('arguments: ${args.join(' ')}');
  }
}
