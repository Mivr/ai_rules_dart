// A `Glyph` built at run time, which `glyphs`' link hook refuses.

import 'package:flutter/material.dart';
import 'package:glyphs/glyphs.dart';

void main() {
  final name = DateTime.now().isUtc ? 'star' : 'heart';
  runApp(Text('${Glyph(name)}', textDirection: TextDirection.ltr));
}
