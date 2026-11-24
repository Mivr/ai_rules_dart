/// The error type for input the checker cannot use.
library;

/// An input the check cannot read: a missing extract, list or source file, or
/// bytes that are not a `ModuleInfo`. It fails the run rather than skipping.
class DocCheckFailure implements Exception {
  /// Creates a failure described by [message].
  const new(this.message);

  /// What went wrong, naming the file involved.
  final String message;

  @override
  String toString() => message;
}
