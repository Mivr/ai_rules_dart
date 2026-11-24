import 'package:args/args.dart';

import 'src/counter.dart';

void main(List<String> args) {
  ArgParser().parse(args);
  Counter().next();
}
