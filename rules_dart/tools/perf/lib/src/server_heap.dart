/// The Bazel server's heap figures, as `bazel info` reports them.
library;

/// `bazel info` keys read after a flow, in the order they are asked for.
const List<String> serverHeapInfoKeys = [
  'max-heap-size',
  'used-heap-size-after-gc',
];

/// Heap sizes in bytes of the measured server, or why they are unknown.
final class ServerHeap {
  /// Creates a heap reading.
  const ServerHeap({required this.maxHeapBytes, required this.usedAfterGcBytes})
    : error = null;

  /// Creates a reading that could not be taken because of [error].
  const ServerHeap.unavailable(String this.error)
    : maxHeapBytes = 0,
      usedAfterGcBytes = 0;

  /// `max-heap-size` in bytes.
  final int maxHeapBytes;

  /// `used-heap-size-after-gc` in bytes.
  final int usedAfterGcBytes;

  /// Why the figures are unknown, or null.
  final String? error;

  /// The `dart-scale.json` form of this reading.
  Map<String, Object?> toJson() => error != null
      ? {'error': error}
      : {
          'max_heap_bytes': maxHeapBytes,
          'used_heap_after_gc_bytes': usedAfterGcBytes,
        };
}

/// Parses the `key: value` lines of `bazel info max-heap-size ...` output.
///
/// A value is a byte count, or a count with a `KB`, `MB` or `GB` suffix.
/// Throws a [FormatException] naming the key when a figure is missing.
ServerHeap parseServerHeap(String infoOutput) {
  final values = <String, String>{};
  for (final line in infoOutput.split('\n')) {
    final at = line.indexOf(':');
    if (at > 0) values[line.substring(0, at).trim()] = line.substring(at + 1);
  }
  int bytes(String key) {
    final raw = values[key]?.trim();
    final match = raw == null
        ? null
        : RegExp(r'^(\d+)\s*(KB|MB|GB)?$').firstMatch(raw);
    if (match == null) {
      throw FormatException('bazel info $key is not a size: "$raw"');
    }
    final factor = switch (match.group(2)) {
      'KB' => 1 << 10,
      'MB' => 1 << 20,
      'GB' => 1 << 30,
      _ => 1,
    };
    return int.parse(match.group(1)!) * factor;
  }

  return ServerHeap(
    maxHeapBytes: bytes(serverHeapInfoKeys[0]),
    usedAfterGcBytes: bytes(serverHeapInfoKeys[1]),
  );
}
