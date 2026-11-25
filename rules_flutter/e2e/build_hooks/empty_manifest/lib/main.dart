// Constructs a constant `Factor`, which native_link's link hook records.
import 'package:flutter/widgets.dart';
import 'package:native_link/native_link.dart';

void main() => runApp(
  Text('${const Factor(6).times(7)}', textDirection: TextDirection.ltr),
);
