/// The `cycle_a` side of the cycle-break fixture.
library;

/// Returns this side's value; the pubspec edge to `cycle_b` is what the
/// break drops, not a source import.
String cycleA() => 'a';
