"""Tests for shader `platforms` / `flavors` conditions (COV-64).

A `flutter.shaders` entry is validated like an asset entry, but used to
have its conditions dropped, so the shader bundled on every platform. These
tests pin the three parts of the fix:

* the parser keeps `platforms` / `flavors` on a shader entry, with the same
  refusals an asset entry gets;
* the rule carries them into `FlutterInfo.pub_shaders` as tuples, and
  `shader_sources` filters them per platform, leaving unconditional entries
  everywhere;
* a file listed as both an asset and a shader fails analysis, for the
  target's own channels and for pub contributions alike.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterCompiledShadersInfo", "FlutterInfo")
load(
    "//flutter/private:common.bzl",
    "flutter_app_shader_aspect",
    "flutter_web_shader_aspect",
    "shader_sources",
)
load("//flutter/private:flutter_application.bzl", "flutter_application")
load(
    "//flutter/private:flutter_library.bzl",
    "flutter_library",
    "pub_shader_matches_target",
)
load("//flutter/private:flutter_pub_assets.bzl", "asset_entry_problem_error")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_CONDITIONED_PUBSPEC = """\
name: shader_conditions
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: [web]
    - path: shaders/paid_only.frag
      flavors: [paid]
    - path: shaders/any.frag
"""

_SCALAR_PLATFORMS_PUBSPEC = """\
name: shader_scalar_platforms
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: web
"""

_SCALAR_FLAVORS_PUBSPEC = """\
name: shader_scalar_flavors
flutter:
  shaders:
    - path: shaders/paid_only.frag
      flavors: paid
"""

_UNKNOWN_PLATFORM_PUBSPEC = """\
name: shader_unknown_platform
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: [tvos]
"""

_SHADER_TRANSFORMERS_PUBSPEC = """\
name: shader_transformers
flutter:
  shaders:
    - path: shaders/distort.frag
      transformers:
        - package: weave
"""

_SHADER_NULL_TRANSFORMERS_PUBSPEC = """\
name: shader_null_transformers
flutter:
  assets:
    - path: assets/image.png
      transformers:
        - package: weave
  shaders:
    - path: shaders/distort.frag
      transformers: null
"""

def _shader_conditions_survive_parse_test_impl(ctx):
    """A shader map entry keeps its `platforms` and `flavors` lists."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_CONDITIONED_PUBSPEC)
    asserts.equals(env, [], result.asset_errors)
    asserts.equals(env, 3, len(result.shaders))
    asserts.equals(env, ["web"], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)
    asserts.equals(env, ["paid"], result.shaders[1].flavors)
    asserts.equals(env, [], result.shaders[1].platforms)
    return unittest.end(env)

def _shader_unconditional_default_test_impl(ctx):
    """A shader with no conditions reads as the empty lists, as before."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_CONDITIONED_PUBSPEC)
    plain = result.shaders[2]
    asserts.equals(env, "shaders/any.frag", plain.path)
    asserts.equals(env, [], plain.platforms)
    asserts.equals(env, [], plain.flavors)
    return unittest.end(env)

def _assert_shader_refusal(env, content, key, detail):
    """Assert `content` yields one shader refusal naming package, entry, key.

    Args:
        env: The unittest environment.
        content: Full pubspec.yaml content with a malformed shader entry.
        key: The expected refusal key (`platforms` or `flavors`).
        detail: A substring the refusal detail must carry.

    Returns:
        The parsed block, so the caller can pin what survived.
    """
    result = parse_flutter_assets_block(content)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, key, problem.key)
    asserts.equals(env, "shaders/web_only.frag" if key == "platforms" else "shaders/paid_only.frag", problem.path)
    asserts.true(env, detail in problem.detail, problem.detail)
    message = asset_entry_problem_error("shader_pkg", problem)
    for want in ["shader_pkg", problem.path, key]:
        asserts.true(env, want in message, message)
    asserts.equals(env, [], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)
    return result

def _shader_scalar_platforms_refused_test_impl(ctx):
    """A non-list shader `platforms` fails the fetch like an asset entry's."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(env, _SCALAR_PLATFORMS_PUBSPEC, "platforms", "Expected platforms to be a list")
    return unittest.end(env)

def _shader_scalar_flavors_refused_test_impl(ctx):
    """A non-list shader `flavors` fails the fetch like an asset entry's."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(env, _SCALAR_FLAVORS_PUBSPEC, "flavors", "Expected flavors to be a list")
    return unittest.end(env)

def _shader_unknown_platform_refused_test_impl(ctx):
    """An unknown shader platform fails naming the package, entry and key."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(
        env,
        _UNKNOWN_PLATFORM_PUBSPEC,
        "platforms",
        "Invalid platform(s): \"tvos\"",
    )
    return unittest.end(env)

def _shader_transformers_refused_test_impl(ctx):
    """A shader entry with `transformers:` yields one refusal with key `transformers`."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SHADER_TRANSFORMERS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "transformers", problem.key)
    asserts.equals(env, "shaders/distort.frag", problem.path)
    asserts.equals(env, 5, problem.line)
    asserts.true(env, "asset transformers are not supported by rules_flutter." in problem.detail, problem.detail)
    message = asset_entry_problem_error("shader_pkg", problem)
    for want in ["shader_pkg", "shaders/distort.frag", "transformers"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _shader_null_transformers_accepted_test_impl(ctx):
    """A shader entry with `transformers: null` yields none while asset entry still refuses."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SHADER_NULL_TRANSFORMERS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "transformers", problem.key)
    asserts.equals(env, "assets/image.png", problem.path)
    asserts.equals(env, 5, problem.line)
    asserts.equals(env, 1, len(result.shaders))
    asserts.equals(env, "shaders/distort.frag", result.shaders[0].path)
    asserts.equals(env, [], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)
    return unittest.end(env)

def _shader_predicate_flavors_and_legacy_spoke_test_impl(ctx):
    """`pub_shader_matches_target` honors flavors, `tester`, and legacy spokes."""
    env = unittest.begin(ctx)
    legacy = struct(shader_path = "shaders/old.frag")
    asserts.true(env, pub_shader_matches_target(legacy, "android"))
    asserts.true(env, pub_shader_matches_target(legacy, "ios"))

    flavored = struct(flavors = ("paid",), platforms = ())
    asserts.false(env, pub_shader_matches_target(flavored, "android"))
    asserts.false(env, pub_shader_matches_target(flavored, "tester"))
    asserts.false(env, pub_shader_matches_target(flavored, "android", flavor = "free"))
    asserts.true(env, pub_shader_matches_target(flavored, "android", flavor = "paid"))

    web_only = struct(flavors = (), platforms = ("web",))
    asserts.false(env, pub_shader_matches_target(web_only, "android"))
    asserts.false(env, pub_shader_matches_target(web_only, "ios"))
    asserts.true(env, pub_shader_matches_target(web_only, "web"))
    asserts.true(env, pub_shader_matches_target(web_only, "tester"))
    asserts.true(env, pub_shader_matches_target(web_only, None))
    return unittest.end(env)

def _probe_contribution_test_impl(ctx):
    """`pkg_asset_platforms` / `pkg_asset_flavors` reach `pub_shaders` as tuples."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    by_path = {
        entry.shader_path: entry
        for entry in target[FlutterInfo].pub_shaders.to_list()
    }
    asserts.equals(env, ("web",), tuple(by_path["shaders/web_only.frag"].platforms))
    asserts.equals(env, (), tuple(by_path["shaders/web_only.frag"].flavors))
    asserts.equals(env, ("paid",), tuple(by_path["shaders/paid_only.frag"].flavors))
    asserts.equals(env, (), tuple(by_path["shaders/any.frag"].platforms))
    asserts.equals(env, (), tuple(by_path["shaders/any.frag"].flavors))
    return analysistest.end(env)

def _fake_shader_ctx(ctx):
    """A `shader_sources` context over the probe dep, without own shaders.

    Args:
        ctx: The analysistest rule context, carrying `probe_dep`.

    Returns:
        A struct with the `files`, `attr.deps` and `label` fields
        `shader_sources` reads.
    """
    return struct(
        files = struct(shaders = [], shader_includes = []),
        attr = struct(deps = [ctx.attr.probe_dep]),
        label = ctx.label,
    )

def _shader_filter_test_impl(ctx):
    """Only the target platform's shaders are listed; unconditional ones stay."""
    env = analysistest.begin(ctx)
    fake = _fake_shader_ctx(ctx)
    web_key = "packages/shader_probe/shaders/web_only.frag"
    paid_key = "packages/shader_probe/shaders/paid_only.frag"
    any_key = "packages/shader_probe/shaders/any.frag"

    android = shader_sources(fake, "android")
    asserts.false(env, web_key in android, "web-only shader must not be listed for android")
    asserts.false(env, paid_key in android, "flavor-only shader must not be listed without a flavor")
    asserts.true(env, any_key in android, "unconditional shader must stay on android")

    web = shader_sources(fake, "web")
    asserts.true(env, web_key in web, "web-only shader must be listed for web")
    asserts.false(env, paid_key in web, "flavor-only shader must not be listed without a flavor")
    asserts.true(env, any_key in web, "unconditional shader must stay on web")

    ios = shader_sources(fake, "ios")
    asserts.false(env, web_key in ios, "web-only shader must not be listed for ios")
    asserts.true(env, any_key in ios, "unconditional shader must stay on ios")
    return analysistest.end(env)

def _aspect_shader_compile_test_impl(ctx):
    """Only matching pub shaders produce compiled `.iplr` aspect outputs."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    shaders = target[FlutterCompiledShadersInfo].compiled_shaders.to_list()
    for entry in shaders:
        asserts.true(env, entry.file.basename.endswith(".iplr"), entry.file.short_path)
    bundle_paths = sorted([s.bundle_path for s in shaders])
    asserts.equals(env, sorted(ctx.attr.expected_bundle_paths), bundle_paths)
    return analysistest.end(env)

def _sksl_app_actions_test_impl(ctx):
    """Non-web app bundle registers `FlutterShaderCompile` only for matching shaders."""
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterShaderCompile"]
    compiled_inputs = [
        f.short_path
        for a in compiles
        for f in a.inputs.to_list()
        if f.short_path.endswith(".frag")
    ]
    asserts.true(env, any([p.endswith("shaders/any.frag") for p in compiled_inputs]), str(compiled_inputs))
    asserts.false(env, any([p.endswith("shaders/web_only.frag") for p in compiled_inputs]), str(compiled_inputs))
    asserts.false(env, any([p.endswith("shaders/paid_only.frag") for p in compiled_inputs]), str(compiled_inputs))
    return analysistest.end(env)

def _expect_failure_test_impl(ctx):
    """Assert analysis failed with every expected substring."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_probe_contribution_test = analysistest.make(_probe_contribution_test_impl)

_shader_filter_test = analysistest.make(
    _shader_filter_test_impl,
    attrs = {"probe_dep": attr.label(mandatory = True)},
)

_app_aspect_compile_test = analysistest.make(
    _aspect_shader_compile_test_impl,
    extra_target_under_test_aspects = [flutter_app_shader_aspect],
    attrs = {"expected_bundle_paths": attr.string_list(mandatory = True)},
)

_web_aspect_compile_test = analysistest.make(
    _aspect_shader_compile_test_impl,
    extra_target_under_test_aspects = [flutter_web_shader_aspect],
    attrs = {"expected_bundle_paths": attr.string_list(mandatory = True)},
)

_sksl_app_actions_test = analysistest.make(
    _sksl_app_actions_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
    },
)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)

_t0_test = unittest.make(_shader_conditions_survive_parse_test_impl)
_t1_test = unittest.make(_shader_unconditional_default_test_impl)
_t2_test = unittest.make(_shader_scalar_platforms_refused_test_impl)
_t3_test = unittest.make(_shader_scalar_flavors_refused_test_impl)
_t4_test = unittest.make(_shader_unknown_platform_refused_test_impl)
_t5_test = unittest.make(_shader_predicate_flavors_and_legacy_spoke_test_impl)
_t6_test = unittest.make(_shader_transformers_refused_test_impl)
_t7_test = unittest.make(_shader_null_transformers_accepted_test_impl)

def _declare_probe_tests(name):
    """Declares the shader condition probe library and filter/aspect tests.

    Args:
        name: Test name prefix.
    """
    flutter_library(
        name = name + "_probe_lib",
        srcs = ["stub.dart"],
        package_name = "shader_probe",
        pkg_shaders = {
            ":shaders/web_only.frag": "shaders/web_only.frag",
            ":shaders/paid_only.frag": "shaders/paid_only.frag",
            ":shaders/any.frag": "shaders/any.frag",
        },
        pkg_asset_platforms = {
            ":shaders/web_only.frag": ["web"],
        },
        pkg_asset_flavors = {
            ":shaders/paid_only.frag": ["paid"],
        },
        tags = ["manual"],
    )

    _probe_contribution_test(
        name = name + "_probe",
        size = "small",
        target_under_test = ":" + name + "_probe_lib",
    )

    _shader_filter_test(
        name = name + "_filter",
        size = "small",
        target_under_test = ":" + name + "_probe_lib",
        probe_dep = ":" + name + "_probe_lib",
    )

    _app_aspect_compile_test(
        name = name + "_app_aspect",
        size = "small",
        target_under_test = ":" + name + "_probe_lib",
        expected_bundle_paths = ["packages/shader_probe/shaders/any.frag"],
    )

    _web_aspect_compile_test(
        name = name + "_web_aspect",
        size = "small",
        target_under_test = ":" + name + "_probe_lib",
        expected_bundle_paths = [
            "packages/shader_probe/shaders/any.frag",
            "packages/shader_probe/shaders/web_only.frag",
        ],
    )

    flutter_application(
        name = name + "_sksl_app",
        srcs = ["stub.dart"],
        main = "stub.dart",
        package_name = "shader_probe",
        require_sksl_shaders = True,
        tags = ["manual"],
        deps = [":" + name + "_probe_lib"],
    )

    _sksl_app_actions_test(
        name = name + "_sksl_app_actions",
        size = "small",
        target_under_test = ":" + name + "_sksl_app",
    )

def _declare_conflict_tests(name):
    """Declares cross-channel asset-versus-shader conflict analysis tests.

    Args:
        name: Test name prefix.
    """
    flutter_library(
        name = name + "_own_conflict",
        srcs = ["stub.dart"],
        assets = ["shaders/x.frag"],
        shaders = ["shaders/x.frag"],
        tags = ["manual"],
    )

    flutter_library(
        name = name + "_pub_conflict",
        srcs = ["stub.dart"],
        pkg_assets = {":shaders/x.frag": "shaders/x.frag"},
        pkg_shaders = {":shaders/x.frag": "shaders/x.frag"},
        tags = ["manual"],
    )

    flutter_library(
        name = name + "_mixed_conflict",
        srcs = ["stub.dart"],
        pkg_assets = {":shaders/x.frag": "shaders/x.frag"},
        shaders = ["shaders/x.frag"],
        tags = ["manual"],
    )

    _expect_failure_test(
        name = name + "_own_conflict_fails",
        size = "small",
        target_under_test = ":" + name + "_own_conflict",
        expected_substrings = ["`assets`", "`shaders`", "shaders/x.frag", "same file"],
    )

    _expect_failure_test(
        name = name + "_pub_conflict_fails",
        size = "small",
        target_under_test = ":" + name + "_pub_conflict",
        expected_substrings = ["`pkg_assets`", "`pkg_shaders`", "shaders/x.frag", "same file"],
    )

    _expect_failure_test(
        name = name + "_mixed_conflict_fails",
        size = "small",
        target_under_test = ":" + name + "_mixed_conflict",
        expected_substrings = ["`pkg_assets`", "`shaders`", "shaders/x.frag", "same file"],
    )

def shader_conditions_test_suite(name):
    """Declares the shader condition parse, filter and conflict tests.

    Args:
        name: Test name prefix; probe and case targets derive from it.
    """
    _declare_probe_tests(name)
    _declare_conflict_tests(name)
    small_unittest_suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
    )
