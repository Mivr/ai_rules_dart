import 'dart:convert';

import 'package:build/build.dart';

/// A Builder declared to produce `.g.dart` outputs but that emits nothing.
class NoopBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {}
}

/// A Builder that writes [_contents] to its `.g.dart` output.
class FixedOutputBuilder implements Builder {
  /// Creates the builder from its configuration.
  FixedOutputBuilder(this._contents);
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final AssetId outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, _contents);
  }
}

/// Like `FixedOutputBuilder` but parameterised by output extension so a
/// multi-factory `runShim` list can fan out to distinct declared outputs.
class FixedExtensionBuilder implements Builder {
  /// Creates the builder from its configuration.
  FixedExtensionBuilder(this._ext, this._contents);
  final String _ext;
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': [_ext],
  };

  @override
  Future<void> build(BuildStep step) async {
    final AssetId outId = step.inputId.changeExtension(_ext);
    await step.writeAsString(outId, _contents);
  }
}

/// A Builder that throws an `Error` from `build`.
class ThrowingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) {
    throw StateError('intentional failure');
  }
}

/// Throws an [Exception] (rather than the [Error] [ThrowingBuilder]
/// throws) so the shim's `on Exception` failure path is driven too.
class ThrowingExceptionBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) {
    throw const FormatException('intentional checked failure');
  }
}

/// Throws a bare string — neither [Exception] nor [Error] — so the shim's
/// fail-open escape path is driven: only real error types are converted to
/// diagnostics, anything else propagates to the caller.
class ThrowingStringBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) {
    Error.throwWithStackTrace(
      'intentional bare-string failure',
      StackTrace.current,
    );
  }
}

/// Emits log records via `package:build`'s top-level `log`, which only
/// resolves to a captured Logger when the Builder runs inside the
/// `#buildLog` Zone value wired by the shim. Used to guard against the
/// silent-fallback regression documented in
/// `gotcha_build_log_zone_value.md`.
class LoggingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    log.warning('builder-emitted warning');
    log.severe('builder-emitted severe');
  }
}

/// Serialises its own `BuilderOptions.config` as JSON into the declared
/// `.g.dart` output. Used to assert the shim correctly plumbs `--config`
/// → `ShimArgs.config` → `BuilderOptions(config)`.
class ConfigEchoBuilder implements Builder {
  /// Creates the builder from its configuration.
  ConfigEchoBuilder(this._options);
  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final AssetId outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, jsonEncode(_options.config));
  }
}

/// Declares a multi-dot output suffix. Used to verify the shim's output-
/// routing logic matches `.foo.bar.baz` against the declared Bazel output
/// without fracturing on intermediate dots.
class MultiDotExtensionBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.foo.bar.baz'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final AssetId outId = step.inputId.changeExtension('.foo.bar.baz');
    await step.writeAsString(outId, '// multi-dot payload\n');
  }
}

/// Builder with a caller-supplied `buildExtensions` map and an optional
/// write callback. Used to exercise the shim's validation of unsupported
/// buildExtensions key shapes (empty string, `$lib$`/`$package$`).
class ExtensionMapBuilder implements Builder {
  /// Creates the builder from its configuration.
  ExtensionMapBuilder(this.buildExtensions, {this.write});

  @override
  final Map<String, List<String>> buildExtensions;

  /// Runs when the builder builds, if set.
  final Future<void> Function(BuildStep)? write;

  @override
  Future<void> build(BuildStep step) async {
    await write?.call(step);
  }
}

/// A Builder that runs a caller-supplied callback with each [BuildStep].
class CapturingBuilder implements Builder {
  /// Creates the builder from its configuration.
  CapturingBuilder(this._fn);
  final Future<void> Function(BuildStep) _fn;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) => _fn(step);
}

/// Builder that emits one asset per entry in [_bodies]; keys are the
/// output extensions (e.g. `.config.dart`), values are the bytes written.
/// Used to exercise the shim's multi-output routing.
class MultiOutputBuilder implements Builder {
  /// Creates the builder from its configuration.
  MultiOutputBuilder(this._bodies);
  final Map<String, String> _bodies;

  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': _bodies.keys.toList(growable: false),
  };

  @override
  Future<void> build(BuildStep step) async {
    for (final MapEntry<String, String> entry in _bodies.entries) {
      final AssetId outId = step.inputId.changeExtension(entry.key);
      await step.writeAsString(outId, entry.value);
    }
  }
}
