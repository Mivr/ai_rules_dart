"""Dart source generated for the web build: the `dart:ui_web` and
`flutter_web_plugins` stubs and the bootstrap wrapper `main.dart`.

Split from `common.bzl`; pure string builders with no rule context.
"""

visibility(["//flutter/..."])

def _web_ui_web_head_lines():
    """Imports, `bootstrapEngine` and handler stubs heading the `dart:ui_web` stub."""
    return [
        "// GENERATED — do not edit.",
        "// ignore_for_file: type=lint",
        "import 'dart:async';",
        "import 'dart:ui' as ui;",
        "",
        "Future<void> bootstrapEngine({",
        "  FutureOr<void> Function()? runApp,",
        "  FutureOr<void> Function()? registerPlugins,",
        "}) async {",
        "  await registerPlugins?.call();",
        "  await runApp?.call();",
        "}",
        "",
        "void setPluginHandler(ui.PlatformMessageCallback handler) {}",
        "",
        "typedef EventListener = dynamic Function(Object event);",
        "typedef PopStateListener = void Function(Object? state);",
        "",
    ]

def _web_shared_navigation_lines():
    """Declares the `PlatformLocation`, `BrowserPlatformLocation` and `UrlStrategy` stubs.

    Shared verbatim by the `dart:ui_web` and `flutter_web_plugins` stubs:
    both stand in for web-only navigation types when compiling against a
    platform without them.
    """
    return [
        "abstract interface class PlatformLocation {",
        "  void addPopStateListener(EventListener fn);",
        "  void removePopStateListener(EventListener fn);",
        "  String get pathname;",
        "  String get search;",
        "  String get hash;",
        "  Object? get state;",
        "  void pushState(Object? state, String title, String url);",
        "  void replaceState(Object? state, String title, String url);",
        "  void go(int count);",
        "  String? getBaseHref();",
        "}",
        "",
        "class BrowserPlatformLocation implements PlatformLocation {",
        "  const BrowserPlatformLocation();",
        "",
        "  @override",
        "  void addPopStateListener(EventListener fn) {}",
        "",
        "  @override",
        "  void removePopStateListener(EventListener fn) {}",
        "",
        "  @override",
        "  String get pathname => '';",
        "",
        "  @override",
        "  String get search => '';",
        "",
        "  @override",
        "  String get hash => '';",
        "",
        "  @override",
        "  Object? get state => null;",
        "",
        "  @override",
        "  void pushState(Object? state, String title, String url) {}",
        "",
        "  @override",
        "  void replaceState(Object? state, String title, String url) {}",
        "",
        "  @override",
        "  void go(int count) {}",
        "",
        "  @override",
        "  String? getBaseHref() => null;",
        "}",
        "",
        "abstract class UrlStrategy {",
        "  const UrlStrategy();",
        "",
        "  ui.VoidCallback addPopStateListener(PopStateListener fn) => () {};",
        "  String getPath() => '';",
        "  Object? getState() => null;",
        "  String prepareExternalUrl(String internalUrl) => '';",
        "  void pushState(Object? state, String title, String url) {}",
        "  void replaceState(Object? state, String title, String url) {}",
        "  Future<void> go(int count) async {}",
        "}",
        "",
    ]

def _web_ui_web_tail_lines():
    """The default `urlStrategy` and `HashUrlStrategy` closing the `dart:ui_web` stub."""
    return [
        "UrlStrategy? urlStrategy;",
        "",
        "class HashUrlStrategy extends UrlStrategy {",
        "  const HashUrlStrategy([",
        "    this._platformLocation = const BrowserPlatformLocation(),",
        "  ]);",
        "",
        "  final PlatformLocation _platformLocation;",
        "",
        "  @override",
        "  String getPath() => _platformLocation.hash;",
        "}",
        "",
    ]

def make_web_ui_web_stub_content():
    """Generate a VM-compatible stub for `dart:ui_web` used during icon tree-shaking kernel compilation.

    Provides the `dart:ui_web` entrypoints referenced by the web bootstrap
    wrapper (`bootstrapEngine`) and by the real `package:flutter_web_plugins`
    sources (`setPluginHandler` and the URL strategy / platform location types
    re-exported by `src/navigation/url_strategy.dart`) for compiles against a
    platform without `dart:ui_web`, which select it through the wrapper's
    conditional import.

    Returns:
      The Dart source text of the stub library, as a single string.
    """
    return "\n".join(_web_ui_web_head_lines() + _web_shared_navigation_lines() + _web_ui_web_tail_lines())

def _web_plugins_base_import_lines():
    """The `library` and `dart:` imports heading the `flutter_web_plugins` stub."""
    return [
        "// GENERATED — do not edit.",
        "// ignore_for_file: type=lint",
        "library flutter_web_plugins;",
        "",
        "import 'dart:async';",
        "import 'dart:typed_data';",
        "import 'dart:ui' as ui;",
    ]

def _web_plugins_foundation_import_lines():
    """`package:flutter` imports when `flutter/services.dart` is present."""
    return [
        "",
        "import 'package:flutter/foundation.dart';",
        "import 'package:flutter/services.dart';",
    ]

def _web_plugins_local_channel_lines():
    """Local `BinaryMessenger`/`MethodCodec` stubs when `flutter/services.dart` is absent."""
    return [
        "",
        "typedef MessageHandler = Future<ByteData?> Function(ByteData? message);",
        "",
        "abstract class BinaryMessenger {",
        "  const BinaryMessenger();",
        "  Future<void> handlePlatformMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  );",
        "  Future<ByteData?>? send(String channel, ByteData? message);",
        "  void setMessageHandler(String channel, MessageHandler? handler);",
        "}",
        "",
        "class MethodCall {",
        "  const MethodCall(this.method, [this.arguments]);",
        "  final String method;",
        "  final dynamic arguments;",
        "}",
        "",
        "abstract class MethodCodec {",
        "  const MethodCodec();",
        "  ByteData? encodeMethodCall(MethodCall methodCall);",
        "  MethodCall decodeMethodCall(ByteData? methodCall);",
        "  dynamic decodeEnvelope(ByteData envelope);",
        "  ByteData encodeSuccessEnvelope(Object? result);",
        "  ByteData encodeErrorEnvelope({",
        "    required String code,",
        "    String? message,",
        "    Object? details,",
        "  });",
        "}",
        "",
        "class StandardMethodCodec implements MethodCodec {",
        "  const StandardMethodCodec();",
        "",
        "  @override",
        "  ByteData? encodeMethodCall(MethodCall methodCall) => null;",
        "",
        "  @override",
        "  MethodCall decodeMethodCall(ByteData? methodCall) => const MethodCall('');",
        "",
        "  @override",
        "  dynamic decodeEnvelope(ByteData envelope) => null;",
        "",
        "  @override",
        "  ByteData encodeSuccessEnvelope(Object? result) => ByteData(0);",
        "",
        "  @override",
        "  ByteData encodeErrorEnvelope({",
        "    required String code,",
        "    String? message,",
        "    Object? details,",
        "  }) => ByteData(0);",
        "}",
    ]

def _web_plugins_messenger_lines():
    """The `Registrar`/`PluginRegistry`/`PluginEventChannel` section of the plugins stub."""
    return [
        "",
        "class Registrar extends BinaryMessenger {",
        "  Registrar([BinaryMessenger? binaryMessenger]);",
        "",
        "  void registerMessageHandler() {}",
        "",
        "  @override",
        "  Future<void> handlePlatformMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  ) => handleFrameworkMessage(channel, data, callback);",
        "",
        "  Future<void> handleFrameworkMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  ) async {",
        "    callback?.call(null);",
        "  }",
        "",
        "  BinaryMessenger get messenger => this;",
        "",
        "  @override",
        "  Future<ByteData?> send(String channel, ByteData? message) async => null;",
        "",
        "  @override",
        "  void setMessageHandler(String channel, MessageHandler? handler) {}",
        "}",
        "",
        "class PluginRegistry extends Registrar {",
        "  PluginRegistry([BinaryMessenger? binaryMessenger]) : super(binaryMessenger);",
        "",
        "  Registrar registrarFor(Type key) => this;",
        "}",
        "",
        "final Registrar webPluginRegistrar = PluginRegistry();",
        "",
        "PluginRegistry get webPluginRegistry => webPluginRegistrar as PluginRegistry;",
        "",
        "BinaryMessenger get pluginBinaryMessenger => webPluginRegistrar;",
        "",
        "class PluginEventChannel<T> {",
        "  const PluginEventChannel(",
        "    this.name, [",
        "    this.codec = const StandardMethodCodec(),",
        "    this.binaryMessenger,",
        "  ]);",
        "",
        "  final String name;",
        "  final MethodCodec codec;",
        "  final BinaryMessenger? binaryMessenger;",
        "",
        "  set controller(StreamController<T> controller) {",
        "    setController(controller);",
        "  }",
        "",
        "  void setController(StreamController<T>? controller) {}",
        "}",
        "",
    ]

def _web_plugins_typedef_lines():
    """The navigation listener typedefs shared with the `dart:ui_web` stub header."""
    return [
        "typedef EventListener = dynamic Function(Object event);",
        "typedef PopStateListener = void Function(Object? state);",
        "",
    ]

def _web_plugins_strategy_tail_lines():
    """The `urlStrategy` accessors and path-strategy helpers closing the plugins stub."""
    return [
        "UrlStrategy? get urlStrategy => null;",
        "void setUrlStrategy(UrlStrategy? strategy) {}",
        "void usePathUrlStrategy() {}",
        "",
        "class HashUrlStrategy extends UrlStrategy {",
        "  const HashUrlStrategy([",
        "    this._platformLocation = const BrowserPlatformLocation(),",
        "  ]);",
        "",
        "  final PlatformLocation _platformLocation;",
        "",
        "  @override",
        "  String getPath() => _platformLocation.hash;",
        "}",
        "",
        "class PathUrlStrategy extends HashUrlStrategy {",
        "  PathUrlStrategy([",
        "    super.platformLocation,",
        "    this.includeHash = false,",
        "  ]);",
        "",
        "  final bool includeHash;",
        "}",
        "",
        "String extractPathname(String url) => ensureLeadingSlash(Uri.parse(url).path);",
        "String checkBaseHref(String? baseHref) => baseHref ?? '/';",
        "String ensureLeadingSlash(String path) => path.startsWith('/') ? path : '/$path';",
        "String stripTrailingSlash(String path) =>",
        "    path.endsWith('/') ? path.substring(0, path.length - 1) : path;",
        "",
    ]

def make_web_plugins_stub_content(has_flutter_services = False):
    """Generate a fallback `package:flutter_web_plugins/flutter_web_plugins.dart` for synthetic test targets without `@deps//:flutter_web_plugins`.

    Args:
        has_flutter_services: Whether `package:flutter/services.dart` is present
            in the target's `flutter` package sources.

    Returns:
        String of Dart source code.
    """
    header = _web_plugins_base_import_lines()
    if has_flutter_services:
        header += _web_plugins_foundation_import_lines()
    else:
        header += _web_plugins_local_channel_lines()
    return "\n".join(
        header + _web_plugins_messenger_lines() + _web_plugins_typedef_lines() +
        _web_shared_navigation_lines() + _web_plugins_strategy_tail_lines(),
    )

def make_web_wrapper_main_content(original_import, registrant_import = None, ui_web_stub_import = None):
    """Generate a web wrapper main.dart that uses ui_web.bootstrapEngine().

    Flutter web requires ui_web.bootstrapEngine() to properly initialize the
    engine (create the implicit view, set up the platform dispatcher, etc.)
    before calling the user's main(). Without this, runApp() fails with
    "The app requested a view, but the platform did not provide one."

    This matches the wrapper that `flutter build web` generates.

    Args:
        original_import: Import URI for the original main.
        registrant_import: Optional relative import path for the generated
            registrant file. If None, plugin registration is a no-op.
        ui_web_stub_import: Optional relative import path for a VM-compatible
            `dart:ui_web` stub, conditionally selected when `dart.library.ui_web`
            is absent (as in the `--target=flutter` icon tree-shaking kernel).

    Returns:
        String of Dart source code.
    """
    ui_web_import = (
        "import '%s' if (dart.library.ui_web) 'dart:ui_web' as ui_web;" % ui_web_stub_import if ui_web_stub_import else "import 'dart:ui_web' as ui_web;"
    )
    lines = [
        "// GENERATED — do not edit.",
        "// Flutter web bootstrap script.",
        "// ignore_for_file: type=lint",
        "",
        ui_web_import,
        "import 'dart:async';",
        "",
        "import '%s' as entrypoint;" % original_import,
    ]
    if registrant_import:
        lines.append("import '%s' as pluginRegistrant;" % registrant_import)
    lines.extend([
        "",
        "typedef _UnaryFunction = dynamic Function(List<String> args);",
        "typedef _NullaryFunction = dynamic Function();",
        "",
        "Future<void> main() async {",
        "  await ui_web.bootstrapEngine(",
        "    runApp: () {",
        "      if (entrypoint.main is _UnaryFunction) {",
        "        return (entrypoint.main as _UnaryFunction)(<String>[]);",
        "      }",
        "      return (entrypoint.main as _NullaryFunction)();",
        "    },",
    ])
    if registrant_import:
        lines.append("    registerPlugins: () {")
        lines.append("      pluginRegistrant.registerPlugins();")
        lines.append("    },")
    lines.extend([
        "  );",
        "}",
        "",
    ])
    return "\n".join(lines)
