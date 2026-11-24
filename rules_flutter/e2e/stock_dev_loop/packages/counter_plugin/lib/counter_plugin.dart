import 'dart:convert';
import 'dart:developer';

/// A plugin with Dart code. The plugin registrant calls [CounterPlugin.registerWith] before
/// `main()`, so [registered] is true only when the running program has a registrant.
class CounterPlugin {
  static bool registered = false;

  static void registerWith() {
    registered = true;
    // A service extension registered the way a debug agent shipped as a plugin would be: the
    // registrant is part of every program the stock tool compiles, so it survives a hot restart,
    // and `app.callServiceExtension` reaches it.
    registerExtension('ext.counter_plugin.mark', (String method, Map<String, String> params) async {
      return ServiceExtensionResponse.result(jsonEncode(<String, Object?>{'mark': mark()}));
    });
  }

  /// The marker a hot reload of the plugin's Dart code changes.
  static String mark() => 'plugin0';
}
