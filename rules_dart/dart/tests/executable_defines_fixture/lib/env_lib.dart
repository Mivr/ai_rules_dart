import 'package:executable_defines_base/base_lib.dart';

/// The defines a dependency module reads, joined.
const String envValue =
    '$baseValue/${String.fromEnvironment('B', defaultValue: 'UNSET')}';
