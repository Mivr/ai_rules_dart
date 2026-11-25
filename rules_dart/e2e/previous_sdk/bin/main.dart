import 'dart:io';

import 'package:previous_sdk/previous_sdk.dart';

void main() {
  stdout
    ..writeln('Dart ${Platform.version.split(' ').first}')
    ..writeln(joinAll(['usr', 'local', 'bin']));
}
