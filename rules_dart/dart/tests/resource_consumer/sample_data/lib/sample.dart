/// A package whose `lib/` ships a non-Dart file, for the runtime package config
/// tests.
library;

import 'package:extra_data/extra.dart';

const String sampleData = 'sample_data';

/// The package reached through this one.
const String reached = extraData;
