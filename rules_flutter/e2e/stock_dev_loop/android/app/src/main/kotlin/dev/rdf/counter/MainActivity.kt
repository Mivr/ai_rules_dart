package dev.rdf.counter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The marker a Kotlin edit changes: it needs a rebuild, a reinstall and a restart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rdf/native").setMethodCallHandler { call, result ->
            if (call.method == "nativeMark") result.success("native0") else result.notImplemented()
        }
    }
}
