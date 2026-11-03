import 'package:smoke/greeting.dart';

void main() {
  // The marker the JS output test looks for.
  // dart:io is unavailable on the web, so print is the only output.
  // ignore: avoid_print
  print('smoke-js-marker: ${greet('web')}');
}
