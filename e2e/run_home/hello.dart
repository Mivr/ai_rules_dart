import 'dart:io';

void main(List<String> args) {
  var code = 0;
  for (final arg in args) {
    if (arg.startsWith('--exit=')) {
      code = int.parse(arg.substring('--exit='.length));
    }
  }
  stdout.writeln('hello ${args.join(' ')}');
  exit(code);
}
