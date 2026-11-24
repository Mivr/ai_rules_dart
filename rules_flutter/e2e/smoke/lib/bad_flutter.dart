// Deliberate red path for `//:bad_flutter_lib`: the private top-level function
// below is never used, so the analyzer reports exactly one `unused_element`
// diagnostic. Its `dart:ui` use only resolves through the `sky_engine`
// closure `flutter_library` hands the analyzer.
import 'dart:ui' as ui;

ui.Color _unusedOpaqueBlack() => const ui.Color(0xFF000000);
