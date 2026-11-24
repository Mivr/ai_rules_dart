# The app's own keep rules, named by the release build type in build.gradle.kts. The plugins' rules
# come from their consumer rule files, and the Flutter tool adds its own.

# Keep the runner activity that the manifest references.
-keep class com.example.plugin_example.MainActivity { *; }

# Keep the auto-generated Flutter plugin registrant.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# androidx.window probes reflectively for vendor-provided sidecar
# classes; suppressing missing-class warnings is the standard
# Flutter-Android pattern (matches what flutter create's app proguard
# emits).
-dontwarn androidx.window.**
-dontwarn com.google.common.util.concurrent.ListenableFuture
