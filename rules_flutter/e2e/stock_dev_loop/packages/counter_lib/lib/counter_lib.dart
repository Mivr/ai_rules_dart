/// A library that lives in another package: `//packages/counter_lib` for
/// Bazel, a path dependency for the stock tool.
library;

/// The marker a hot reload changes; the app prints it on every build.
String libMark() => 'lib0';

/// Formats the counter value.
String describeCount(int count) {
  final String mark = libMark();
  return 'count $count ($mark)';
}
