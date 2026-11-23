// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _uri =
    'org-dartlang-app:///_flutter_debug_agent/plugin_registrant.dart';

/// Whether the dill at [envVar]'s path holds the registrant URI.
bool _holdsUri(String envVar) {
  final String path = Runfiles.create().rlocation(
    Platform.environment[envVar]!,
  );
  final String text = latin1.decode(File(path).readAsBytesSync());
  return text.contains(_uri);
}

void main() {
  test('the plain link does not hold the registrant URI', () {
    expect(_holdsUri('PLAIN_DILL'), isFalse);
  });

  test('the link over the twin holds the constant registrant URI', () {
    expect(_holdsUri('SWAPPED_DILL'), isTrue);
  });
}
