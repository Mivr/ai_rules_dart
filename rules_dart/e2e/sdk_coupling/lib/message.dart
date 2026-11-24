part 'message.g.dart';

/// Returns the greeting assembled through `dart_source_set` (`copy_tree`).
String stagedGreeting() => 'staged: ${generatedMessage()}';
