import 'dart:io';

import 'package:args/args.dart';

// Builds only if the default-conflict hub for this workspace's older args lock
// resolves instead of failing against rules_dart's own tool lock.
void main(List<String> arguments) {
  final parser = ArgParser()..addFlag('verbose');
  stdout.writeln('args: ${parser.parse(arguments)['verbose']}');
}
