"""Conditional Dart snippets for the `flutter_integration_test` bootstrap templates.

The bootstrap programs themselves are template files in
`flutter/private/integration_test_bootstrap/`, expanded per target with
`ctx.actions.expand_template`. That action substitutes strings, never file
contents, so the two snippets a target chooses between — the live binding
declaration and the harness-URL prologue — are defined here, once, and passed
as substitutions. Each snippet stays well under the length that makes a
literal a template (see `integration_test_bootstrap/*.dart.tpl` for those).
"""

visibility(["//flutter/..."])

# The binding the bootstrap uses when `deps` does not expose
# `package:integration_test`: a `LiveTestWidgetsFlutterBinding` that keeps the
# app's own HTTP client and text input registration and follows the surface
# size the integration test sets. One definition; every platform bootstrap
# substitutes the same text.
_LIVE_BINDING_DECL = """
class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding {
  static _IntegrationTestBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static _IntegrationTestBinding ensureInitialized() {
    if (_instance == null) {
      _IntegrationTestBinding();
    }
    return _instance!;
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final FlutterView view = renderView.flutterView;
    final Size? surfaceSize =
        view == platformDispatcher.implicitView ? _surfaceSize : null;
    return TestViewConfiguration.fromView(
      size: surfaceSize ?? view.physicalSize / view.devicePixelRatio,
      view: view,
    );
  }

  @override
  void setLabel(String value) {}

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {}
}
"""

# The harness-URL prologue that `linux_bootstrap.dart.tpl` substitutes: the
# runner passes the URL through the test environment, and a missing value
# fails the run before it dials anything.
LINUX_HARNESS_URL_PROLOGUE = """  final wsUrl = Platform.environment['FLUTTER_INTEGRATION_TEST_HARNESS_URL'];
  if (wsUrl == null || wsUrl.isEmpty) {
    stderr.writeln(
      'flutter_integration_test bootstrap: '
      'FLUTTER_INTEGRATION_TEST_HARNESS_URL not set',
    );
    exit(64);
  }
"""

# Name of the harness-URL file the launcher writes under the app data
# container's `tmp/`. Must match `iosHarnessUrlFileName` in
# `flutter/private/tools/flutter_integration_test_ios.dart`.
_IOS_HARNESS_URL_FILE_NAME = "flutter_integration_test_harness_url"

# The iOS prologue: the environment first, then the launcher-written file.
# `Platform.environment` is always empty on iOS (the Dart SDK returns no
# entries under DART_HOST_OS_IOS; flutter/flutter#114849), so the
# `SIMCTL_CHILD_` launch environment never reaches Dart; the launcher instead
# writes the per-launch URL into a file under the app data container's `tmp/`
# after install, which the app reads here as `Directory.systemTemp`. Missing
# both still fails with the shared message, flushed before exit (without the
# flush the message can be lost). No fixed-port fallback: the URL is always
# the runner's per-launch one.
IOS_HARNESS_URL_PROLOGUE = """  var wsUrl = Platform.environment['FLUTTER_INTEGRATION_TEST_HARNESS_URL'];
  if (wsUrl == null || wsUrl.isEmpty) {
    // `Platform.environment` is always empty on iOS (the Dart SDK returns no
    // entries under DART_HOST_OS_IOS; flutter/flutter#114849), so the
    // `SIMCTL_CHILD_` launch environment never reaches Dart. The launcher
    // writes the per-launch URL into a file under the app data container's
    // `tmp/` after install, which the app reads here as `Directory.systemTemp`.
    try {
      final String fileUrl = await File(
        '${Directory.systemTemp.path}/""" + _IOS_HARNESS_URL_FILE_NAME + """',
      ).readAsString();
      if (fileUrl.trim().isNotEmpty) {
        wsUrl = fileUrl.trim();
      }
    } on Exception catch (_) {
      // A missing or unreadable file falls through to the failure below.
    }
  }
  if (wsUrl == null || wsUrl.isEmpty) {
    stderr.writeln(
      'flutter_integration_test bootstrap: '
      'FLUTTER_INTEGRATION_TEST_HARNESS_URL not set',
    );
    await stderr.flush();
    exit(64);
  }
"""

def integration_test_binding_substitutions(has_integration_test):
    """The binding snippets a bootstrap substitutes.

    Args:
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A struct with `import_stmt`, `decl` and `init`: the import line
        (`""` when absent), the class declaration (`""` when unused), and the
        initialization statement the bootstrap calls.
    """
    if has_integration_test:
        return struct(
            decl = "",
            import_stmt = "import 'package:integration_test/integration_test.dart';\n",
            init = "IntegrationTestWidgetsFlutterBinding.ensureInitialized();",
        )
    return struct(
        decl = _LIVE_BINDING_DECL,
        import_stmt = "",
        init = "_IntegrationTestBinding.ensureInitialized();",
    )
