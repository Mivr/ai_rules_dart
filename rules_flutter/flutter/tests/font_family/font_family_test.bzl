"""Analysis tests for the COV-29 font-family contract.

Every refusal fails on the base: the misbinding (a font paired with the file
at its index), a weight or style flutter_tools rejects, an application's
families, and the duplicate-family conflict. The positive cases inspect the
bundle config: an application's family and assets are bare, a library's are
`packages/<package_name>/`, each descriptor lists `weight`/`style` only when
given, and every asset maps to its own file.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/tests:action_content.bzl", "written_json")

visibility(["//flutter/tests/..."])

def _assert_copy(env, config, dest, suffix):
    """Assert the bundle copies `dest` from the file ending in `suffix`.

    Args:
        env: The `analysistest` env.
        config: Decoded `.asset_bundle_config.json`.
        dest: The bundled destination key.
        suffix: The source path suffix the copied file must carry.
    """
    copies = config["copies"]
    asserts.true(env, dest in copies, "no bundle copy for %s: %s" % (dest, copies))
    if dest in copies:
        asserts.true(
            env,
            copies[dest].endswith(suffix),
            "bundle copy %s came from %s, not a file ending in %s" % (dest, copies[dest], suffix),
        )

def _app_fonts_test_impl(ctx):
    """Verify `flutter_application.fonts` emits bare family and asset paths."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    asserts.equals(
        env,
        [{
            "family": "HelloSans",
            "fonts": [
                {"asset": "fonts/HelloSans-Regular.ttf"},
                {"asset": "fonts/HelloSans-Bold.ttf", "weight": 700},
            ],
        }],
        config["fonts"],
    )
    _assert_copy(env, config, "fonts/HelloSans-Regular.ttf", "font_family/fonts/HelloSans-Regular.ttf")
    _assert_copy(env, config, "fonts/HelloSans-Bold.ttf", "font_family/fonts/HelloSans-Bold.ttf")
    return analysistest.end(env)

def _library_fonts_test_impl(ctx):
    """Verify `flutter_library.fonts` prefixes `packages/<package_name>/`."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    asserts.equals(
        env,
        [{
            "family": "packages/fontpkg/HelloSans",
            "fonts": [
                {"asset": "packages/fontpkg/fonts/HelloSans-Regular.ttf"},
                {"asset": "packages/fontpkg/fonts/HelloSans-Bold.ttf", "weight": 700},
            ],
        }],
        config["fonts"],
    )
    _assert_copy(
        env,
        config,
        "packages/fontpkg/fonts/HelloSans-Regular.ttf",
        "font_family/fonts/HelloSans-Regular.ttf",
    )
    _assert_copy(
        env,
        config,
        "packages/fontpkg/fonts/HelloSans-Bold.ttf",
        "font_family/fonts/HelloSans-Bold.ttf",
    )
    return analysistest.end(env)

def _library_default_pkg_fonts_test_impl(ctx):
    """Verify `flutter_library.fonts` uses the derived package name when omitted."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    asserts.equals(
        env,
        [{
            "family": "packages/font_family/StyledSans",
            "fonts": [{
                "asset": "packages/font_family/fonts/HelloSans-Regular.ttf",
                "style": "italic",
                "weight": 400,
            }],
        }],
        config["fonts"],
    )
    _assert_copy(
        env,
        config,
        "packages/font_family/fonts/HelloSans-Regular.ttf",
        "font_family/fonts/HelloSans-Regular.ttf",
    )
    return analysistest.end(env)

def _failure_test_impl(ctx):
    """Verify analysis fails with every expected substring in the error."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_app_fonts_test = analysistest.make(
    _app_fonts_test_impl,
    doc = "Inspects `.asset_bundle_config.json` on an application using `fonts`.",
)

_library_fonts_test = analysistest.make(
    _library_fonts_test_impl,
    doc = "Inspects `.asset_bundle_config.json` on a library using `fonts`.",
)

_library_default_pkg_fonts_test = analysistest.make(
    _library_default_pkg_fonts_test_impl,
    doc = "Inspects `.asset_bundle_config.json` when a library omits `package_name`.",
)

_failure_test = analysistest.make(
    _failure_test_impl,
    doc = "Asserts `target_under_test` fails analysis with `expected` substrings.",
    expect_failure = True,
    attrs = {
        "expected": attr.string_list(
            doc = "Substrings that must appear in the analysis failure message.",
            mandatory = True,
        ),
    },
)

def _failure(tests, name, target, expected):
    """Register one expected-analysis-failure test and record its label.

    Args:
        tests: Suite test-label accumulator list.
        name: Test target name.
        target: The fixture target under test.
        expected: Substrings the failure must name.
    """
    _failure_test(
        name = name,
        size = "small",
        expected = expected,
        target_under_test = target,
    )
    tests.append(":" + name)

def _register_positive_tests(name, tests):
    """Register the positive bundle-config inspection tests.

    Args:
        name: Suite prefix.
        tests: Suite test-label accumulator list.
    """
    _app_fonts_test(
        name = name + "_app_fonts",
        size = "small",
        target_under_test = ":app_with_fonts",
    )
    tests.append(":" + name + "_app_fonts")
    _library_fonts_test(
        name = name + "_library_fonts",
        size = "small",
        target_under_test = ":lib_fonts_bundle",
    )
    tests.append(":" + name + "_library_fonts")
    _library_default_pkg_fonts_test(
        name = name + "_library_default_pkg_fonts",
        size = "small",
        target_under_test = ":lib_default_pkg_bundle",
    )
    tests.append(":" + name + "_library_default_pkg_fonts")

def _register_json_refusal_tests(name, tests):
    """Register the `fonts_json` / `font_files` fail-closed analysis tests.

    Args:
        name: Suite prefix.
        tests: Suite test-label accumulator list.
    """
    cases = [
        ("_missing_font_file", ":missing_file_lib", ["missing_file_lib", "HelloSans", "fonts/HelloSans-Regular.ttf has no font_files entry"]),
        ("_missing_font_file_plugin", ":missing_file_plugin", ["missing_file_plugin", "HelloSans", "fonts/HelloSans-Regular.ttf has no font_files entry"]),
        ("_unclaimed_font_file", ":unclaimed_file_lib", ["unclaimed_file_lib", "HelloSans", "fonts/HelloSans-Bold.ttf is named by no family"]),
        ("_unclaimed_no_json", ":unclaimed_no_json_lib", ["unclaimed_no_json_lib", "fonts/HelloSans-Bold.ttf is named by no family"]),
        ("_bad_weight_json", ":bad_weight_lib", ["bad_weight_lib", "HelloSans", "fonts/HelloSans-Regular.ttf", "Invalid value 750 ((int)) for font -> weight."]),
        ("_null_weight_json", ":null_weight_lib", ["null_weight_lib", "HelloSans", "fonts/HelloSans-Regular.ttf", "Invalid value null ((Null)) for font -> weight."]),
        ("_bad_style_json", ":bad_style_lib", ["bad_style_lib", "HelloSans", "fonts/HelloSans-Regular.ttf", "Invalid value oblique ((String)) for font -> style."]),
        ("_bad_weight_plugin", ":bad_weight_plugin", ["bad_weight_plugin", "HelloSans", "fonts/HelloSans-Regular.ttf", "Invalid value 750 ((int)) for font -> weight."]),
        ("_bad_style_plugin", ":bad_style_plugin", ["bad_style_plugin", "HelloSans", "fonts/HelloSans-Regular.ttf", "Invalid value oblique ((String)) for font -> style."]),
    ]
    for suffix, target, expected in cases:
        _failure(tests, name + suffix, target, expected)

def _register_family_refusal_tests(name, tests):
    """Register the `flutter_font_family` analysis-failure tests.

    Args:
        name: Suite prefix.
        tests: Suite test-label accumulator list.
    """
    cases = [
        ("_empty_family", ":empty_family", ["empty_family", "non-empty `family`"]),
        ("_empty_fonts", ":empty_fonts", ["empty_fonts", "non-empty `fonts` list"]),
        ("_missing_asset", ":missing_asset_family", ["missing_asset_family", "NoAssetSans", "no asset path"]),
        ("_bad_weight_family", ":bad_weight_family", ["bad_weight_family", "HeavySans", "fonts/HelloSans-Regular.ttf", "Invalid value 750 ((int)) for font -> weight."]),
        ("_bad_style_family", ":bad_style_family", ["bad_style_family", "SlantedSans", "fonts/HelloSans-Regular.ttf", "Invalid value oblique ((String)) for font -> style."]),
        ("_escaping_asset_family", ":escaping_asset_family", ["escaping_asset_family", "EscapeSans", "../outside.ttf"]),
    ]
    for suffix, target, expected in cases:
        _failure(tests, name + suffix, target, expected)

def _register_conflict_tests(name, tests):
    """Register the duplicate-family conflict analysis tests.

    Args:
        name: Suite prefix.
        tests: Suite test-label accumulator list.
    """
    cases = [
        ("_conflict_app", ":conflict_app", ["font family 'ConflictSans' is carried with two different font lists", "conflict_a", "conflict_b"]),
        ("_conflict_library", ":conflict_lib", ["font family 'packages/conflictpkg/ConflictSans' is carried with two different font lists", "conflict_a", "conflict_lib"]),
        ("_conflict_library_bundle", ":conflict_lib_bundle", ["font family 'packages/conflictpkg/ConflictSans' is carried with two different font lists", "conflict_a", "conflict_lib"]),
        ("_conflict_app_and_dep", ":conflict_app_and_dep", ["font family 'ConflictSans' is carried with two different font lists", "conflict_a", "conflict_bare_dep"]),
        ("_conflict_single_plugin", ":conflict_single_plugin", ["font family 'packages/single_plugin_pkg/ConflictSans' is carried with two different font lists", "single_plugin_pkg"]),
        ("_conflict_plugin_and_lib", ":conflict_plugin_and_lib_bundle", ["font family 'packages/shared_plugin_pkg/ConflictSans' is carried with two different font lists", "conflict_plugin_a", "conflict_b"]),
    ]
    for suffix, target, expected in cases:
        _failure(tests, name + suffix, target, expected)

def font_family_test_suite(name):
    """Registers the COV-29 analysis tests.

    Args:
        name: Prefix for the generated tests and the suite.
    """
    tests = []
    _register_positive_tests(name, tests)
    _register_json_refusal_tests(name, tests)
    _register_family_refusal_tests(name, tests)
    _register_conflict_tests(name, tests)
    native.test_suite(
        name = name,
        tests = tests,
    )
