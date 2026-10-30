"""The formatter mode `DartFormat` selects for a toolchain SDK and language version.

Kept apart from `dart_analyze_aspect.bzl`, which also declares the aspect, so
that file holds the analysis plumbing rather than the formatter's version table.
`dart_analyze_aspect.bzl` re-exports `resolve_format_mode`, which
`dart/tests/analyze_test.bzl` loads from it.
"""

# The SDK `<major>.<minor>` series whose `dart format` rules match the
# vendored `package:dart_style` in `dart/ext/pubspec.lock`, and the minimum
# patch within that series. When the toolchain's SDK is outside this series or
# the target's language version is outside `FORMATTER_MIN_LANGUAGE_VERSION` ..
# `<sdk_major>.<sdk_minor>`, `DartFormat` declares `compile_files` and
# `format_runner` invokes the SDK's own `dart format` CLI.
FORMATTER_SDK_SERIES = (3, 13)
FORMATTER_MIN_SDK_PATCH = 4
FORMATTER_MIN_LANGUAGE_VERSION = (2, 12)
FORMATTER_MAX_2X_MINOR = 19

def _parse_sdk_version(version):
    """Returns `(major, minor, patch)` of an SDK version string, or None."""
    core = version.split("-")[0].split("+")[0].split(".")
    if len(core) < 2 or not core[0].isdigit() or not core[1].isdigit():
        return None
    patch = 0
    if len(core) >= 3:
        if not core[2].isdigit():
            return None
        patch = int(core[2])
    return (int(core[0]), int(core[1]), patch)

def _parse_language_version(version):
    """Returns `(major, minor)` of a `major.minor` language version, or None."""
    parts = version.split(".")
    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return None
    return (int(parts[0]), int(parts[1]))

def resolve_format_mode(sdk_version, language_version):
    """Decides which formatter and language version `DartFormat` uses.

    Mirrors `resolveFormatMode` in `dart/private/tools/format_runner.dart` so
    the Starlark action gate (whether `compile_files` is declared in `inputs`)
    and `format_runner` (whether formatting runs in-process with the vendored
    `package:dart_style` or shells out to the SDK's `dart format`) always make
    the same choice.

    When `language_version` is empty or `"latest"`, the effective language
    version is the toolchain SDK's own `<major>.<minor>`, never the vendored
    `package:dart_style`'s `latestLanguageVersion`.

    Args:
      sdk_version: The toolchain's `DartSdkInfo.version` (e.g. `"3.13.5"`).
      language_version: The target's package language version (`""`, `"latest"`,
        or `"<major>.<minor>"`).

    Returns:
      `struct(in_process = bool, language_version = str)`.
    """
    sdk = _parse_sdk_version(sdk_version)
    if sdk == None:
        return struct(
            in_process = False,
            language_version = language_version if language_version else "latest",
        )
    sdk_major, sdk_minor, sdk_patch = sdk
    sdk_lv = (sdk_major, sdk_minor)
    if not language_version or language_version == "latest":
        lv = sdk_lv
        effective_lv = "%d.%d" % (sdk_major, sdk_minor)
    else:
        lv = _parse_language_version(language_version)
        if lv == None:
            return struct(
                in_process = False,
                language_version = language_version,
            )
        effective_lv = "%d.%d" % (lv[0], lv[1])

    sdk_matches = (sdk_major, sdk_minor) == FORMATTER_SDK_SERIES and sdk_patch >= FORMATTER_MIN_SDK_PATCH
    lv_valid_2x = lv[0] == 2 and FORMATTER_MIN_LANGUAGE_VERSION[1] <= lv[1] and lv[1] <= FORMATTER_MAX_2X_MINOR
    lv_valid_3x = lv[0] == 3 and 0 <= lv[1] and lv[1] <= FORMATTER_SDK_SERIES[1]
    lv_supported = (lv_valid_2x or lv_valid_3x) and FORMATTER_MIN_LANGUAGE_VERSION <= lv and lv <= sdk_lv
    return struct(
        in_process = sdk_matches and lv_supported,
        language_version = effective_lv,
    )
