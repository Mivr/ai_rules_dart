"""Unit and analysis tests for plugin_federation.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info_no_package")
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps", "dedup_plugins", "flutter_info")
load("//flutter/private:plugin_federation.bzl", "resolve_federated_plugins")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _default_only_test_impl(ctx):
    """With no other implementation, the default implementation stays."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    def_pkg = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    result = resolve_federated_plugins([u, def_pkg], "android")
    asserts.equals(env, ["greeting", "greeting_android"], [p.name for p in result])
    return unittest.end(env)

def _default_replaced_by_app_chosen_test_impl(ctx):
    """An app-chosen implementation replaces the default implementation."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    def_pkg = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    alt_pkg = struct(
        name = "greeting_alt",
        platforms = {"android": {"pluginClass": "GreetingAltPlugin"}},
        implements = "greeting",
        direct = True,
    )
    result = resolve_federated_plugins([u, def_pkg, alt_pkg], "android")
    asserts.equals(env, ["greeting_alt"], [p.name for p in result])
    return unittest.end(env)

def _platform_without_entry_test_impl(ctx):
    """A platform on which the other implementation has no entry is accepted."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {
            "android": {"default_package": "greeting_android"},
            "ios": {"default_package": "greeting_ios"},
        },
        implements = "",
    )
    def_android = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    def_ios = struct(
        name = "greeting_ios",
        platforms = {"ios": {"pluginClass": "GreetingIosPlugin"}},
        implements = "greeting",
    )
    alt_android_only = struct(
        name = "greeting_alt",
        platforms = {"android": {"pluginClass": "GreetingAltPlugin"}},
        implements = "greeting",
        direct = True,
    )
    result_ios = resolve_federated_plugins(
        [u, def_android, def_ios, alt_android_only],
        "ios",
    )
    asserts.true(env, "greeting_ios" in [p.name for p in result_ios])
    asserts.equals(
        env,
        ["greeting", "greeting_android", "greeting_ios", "greeting_alt"],
        [p.name for p in result_ios],
    )

    result_android = resolve_federated_plugins(
        [u, def_android, def_ios, alt_android_only],
        "android",
    )
    asserts.equals(env, ["greeting_alt", "greeting_ios"], [p.name for p in result_android])
    return unittest.end(env)

def _order_preserved_test_impl(ctx):
    """The order of remaining plugins is unchanged."""
    env = unittest.begin(ctx)
    p1 = struct(name = "p1", platforms = {"android": {"pluginClass": "P1"}}, implements = "")
    u = struct(name = "umbrella", platforms = {"android": {"default_package": "def_pkg"}}, implements = "")
    p2 = struct(name = "p2", platforms = {"android": {"pluginClass": "P2"}}, implements = "")
    def_pkg = struct(name = "def_pkg", platforms = {"android": {"pluginClass": "Def"}}, implements = "umbrella")
    p3 = struct(name = "p3", platforms = {"android": {"pluginClass": "P3"}}, implements = "")
    alt = struct(name = "alt", platforms = {"android": {"pluginClass": "Alt"}}, implements = "umbrella", direct = True)
    p4 = struct(name = "p4", platforms = {"android": {"pluginClass": "P4"}}, implements = "")

    result = resolve_federated_plugins([p1, u, p2, def_pkg, p3, alt, p4], "android")
    asserts.equals(env, ["p1", "alt", "p2", "p3", "p4"], [p.name for p in result])
    return unittest.end(env)

def _empty_list_test_impl(ctx):
    """An empty plugin list returns an empty list."""
    env = unittest.begin(ctx)
    result = resolve_federated_plugins([], "android")
    asserts.equals(env, [], result)
    return unittest.end(env)

def _untouched_plugins_test_impl(ctx):
    """A plugin with no implements and no default_package is untouched."""
    env = unittest.begin(ctx)
    p = struct(name = "plain", platforms = {"android": {"pluginClass": "PlainPlugin"}}, implements = "")
    result = resolve_federated_plugins([p], "android")
    asserts.equals(env, [p], result)
    return unittest.end(env)

def _two_alternatives_one_direct_test_impl(ctx):
    """Two alternatives where one is direct resolve to the direct one."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    def_pkg = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
        direct = False,
    )
    alt1 = struct(
        name = "greeting_alt1",
        platforms = {"android": {"pluginClass": "Alt1Plugin"}},
        implements = "greeting",
        direct = True,
    )
    alt2 = struct(
        name = "greeting_alt2",
        platforms = {"android": {"pluginClass": "Alt2Plugin"}},
        implements = "greeting",
        direct = False,
    )
    result = resolve_federated_plugins([u, def_pkg, alt1, alt2], "android")
    asserts.equals(env, ["greeting_alt1"], [p.name for p in result])
    return unittest.end(env)

def _scenario_s1_test_impl(ctx):
    """S1: umbrella reached directly, default registered when alternative is transitive."""
    env = unittest.begin(ctx)
    u = struct(
        name = "foo",
        platforms = {"android": {"default_package": "foo_android"}},
        implements = "",
        direct = True,
    )
    def_pkg = struct(
        name = "foo_android",
        platforms = {"android": {"pluginClass": "FooAndroid"}},
        implements = "foo",
        direct = False,
    )
    foo_alt = struct(
        name = "foo_alt",
        platforms = {"android": {"pluginClass": "FooAlt"}},
        implements = "foo",
        direct = False,
    )
    result = resolve_federated_plugins([u, def_pkg, foo_alt], "android")
    asserts.equals(env, ["foo", "foo_android"], [p.name for p in result])
    return unittest.end(env)

def _scenario_s2_test_impl(ctx):
    """S2: alternative foo_alt direct with another alternative transitive resolves to foo_alt."""
    env = unittest.begin(ctx)
    u = struct(
        name = "foo",
        platforms = {"android": {"default_package": "foo_android"}},
        implements = "",
        direct = True,
    )
    def_pkg = struct(
        name = "foo_android",
        platforms = {"android": {"pluginClass": "FooAndroid"}},
        implements = "foo",
        direct = False,
    )
    foo_alt = struct(
        name = "foo_alt",
        platforms = {"android": {"pluginClass": "FooAlt"}},
        implements = "foo",
        direct = True,
    )
    foo_alt2 = struct(
        name = "foo_alt2",
        platforms = {"android": {"pluginClass": "FooAlt2"}},
        implements = "foo",
        direct = False,
    )
    result = resolve_federated_plugins([u, def_pkg, foo_alt, foo_alt2], "android")
    asserts.equals(env, ["foo_alt"], [p.name for p in result])
    return unittest.end(env)

def _scenario_s3_test_impl(ctx):
    """S3: foo implements itself inline and yields to direct alternative foo_alt."""
    env = unittest.begin(ctx)
    foo = struct(
        name = "foo",
        platforms = {"android": {"pluginClass": "FooInlinePlugin"}},
        implements = "",
        direct = True,
    )
    foo_alt = struct(
        name = "foo_alt",
        platforms = {"android": {"pluginClass": "FooAltPlugin"}},
        implements = "foo",
        direct = True,
    )
    result = resolve_federated_plugins([foo, foo_alt], "android")
    asserts.equals(env, ["foo_alt"], [p.name for p in result])
    return unittest.end(env)

def _dedup_preserves_direct_test_impl(ctx):
    """Deduplication never loses the direct mark regardless of encounter order."""
    env = unittest.begin(ctx)
    p_trans = struct(name = "pkg", platforms = {}, implements = "", direct = False)
    p_direct = struct(name = "pkg", platforms = {}, implements = "", direct = True)

    first_trans = dedup_plugins([p_trans, p_direct])
    asserts.equals(env, 1, len(first_trans))
    asserts.true(env, getattr(first_trans[0], "direct", False))

    first_direct = dedup_plugins([p_direct, p_trans])
    asserts.equals(env, 1, len(first_direct))
    asserts.true(env, getattr(first_direct[0], "direct", False))
    return unittest.end(env)

def _conflict_target_impl(_ctx):
    """Implementation of conflict target rule to trigger duplicate implementations error."""
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    c1 = struct(
        name = "greeting_alt1",
        platforms = {"android": {"pluginClass": "Alt1Plugin"}},
        implements = "greeting",
        direct = True,
    )
    c2 = struct(
        name = "greeting_alt2",
        platforms = {"android": {"pluginClass": "Alt2Plugin"}},
        implements = "greeting",
        direct = True,
    )
    resolve_federated_plugins([u, c1, c2], "android")
    return [DefaultInfo()]

_conflict_target = rule(
    implementation = _conflict_target_impl,
    doc = "Fixture rule that triggers conflicting federated plugin resolution.",
)

def _two_implementations_refused_test_impl(ctx):
    """Two direct implementations fail closed with exact error message."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        'flutter plugin registrant: "greeting" has more than one implementation for android (greeting_alt1, greeting_alt2). Depend on one, or on the default "greeting_android" only.',
    )
    return analysistest.end(env)

_two_implementations_refused_test = analysistest.make(
    _two_implementations_refused_test_impl,
    expect_failure = True,
)

def _scenario_s4_target_impl(_ctx):
    """Implementation of S4 fixture rule to trigger multiple implementations error without default."""
    foo = struct(
        name = "foo",
        platforms = {},
        implements = "",
        direct = True,
    )
    foo_a = struct(
        name = "foo_a",
        platforms = {"android": {"pluginClass": "FooAPlugin"}},
        implements = "foo",
        direct = False,
    )
    foo_b = struct(
        name = "foo_b",
        platforms = {"android": {"pluginClass": "FooBPlugin"}},
        implements = "foo",
        direct = False,
    )
    resolve_federated_plugins([foo, foo_a, foo_b], "android")
    return [DefaultInfo()]

_scenario_s4_target = rule(
    implementation = _scenario_s4_target_impl,
    doc = "Fixture rule that triggers scenario S4 resolution error.",
)

def _scenario_s4_test_impl(ctx):
    """S4: multiple implementations without default and none direct fails closed."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        'flutter plugin registrant: "foo" has more than one implementation for android (foo_a, foo_b). Depend on one only.',
    )
    return analysistest.end(env)

_scenario_s4_test = analysistest.make(
    _scenario_s4_test_impl,
    expect_failure = True,
)

def _absent_default_target_impl(_ctx):
    """Two transitive alternatives while the endorsed default is not a candidate."""
    umbrella = struct(
        name = "sp",
        platforms = {"android": {"default_package": "sp_android"}},
        implements = "",
        direct = True,
    )
    alt_a = struct(
        name = "alt_a",
        platforms = {"android": {"pluginClass": "AltA"}},
        implements = "sp",
        direct = False,
    )
    alt_b = struct(
        name = "alt_b",
        platforms = {"android": {"pluginClass": "AltB"}},
        implements = "sp",
        direct = False,
    )
    resolve_federated_plugins([umbrella, alt_a, alt_b], "android")
    return [DefaultInfo()]

_absent_default_target = rule(
    implementation = _absent_default_target_impl,
    doc = "Fixture rule that resolves an umbrella whose endorsed default is not a candidate.",
)

def _absent_default_refused_test_impl(ctx):
    """An endorsed default outside the candidates is not invented: resolution fails."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, '"sp" has more than one implementation for android (alt_a, alt_b)')
    return analysistest.end(env)

_absent_default_refused_test = analysistest.make(
    _absent_default_refused_test_impl,
    expect_failure = True,
)

# Graph-level direct marking tests
_DirectPluginsInfo = provider(
    doc = "Captures collected plugins for analysis assertions.",
    fields = {"plugins": "List of collected plugin structs"},
)

def _mock_plugin_node_impl(ctx):
    """Implementation of mock plugin node for graph reachability tests."""
    return [
        DefaultInfo(),
        dart_info_no_package(),
        flutter_info(
            deps = ctx.attr.deps,
            plugins = [struct(name = ctx.attr.plugin_name, platforms = {}, implements = "")],
        ),
    ]

_mock_plugin_node = rule(
    implementation = _mock_plugin_node_impl,
    attrs = {
        "plugin_name": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "Mock plugin target for dependency graph tests.",
)

def _mock_library_node_impl(ctx):
    """Implementation of mock library node for graph reachability tests."""
    return [
        DefaultInfo(),
        dart_info_no_package(),
        flutter_info(
            deps = ctx.attr.deps,
            plugins = [],
        ),
    ]

_mock_library_node = rule(
    implementation = _mock_library_node_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "Mock library target for dependency graph tests.",
)

def _graph_collector_impl(ctx):
    """Implementation of graph collector fixture."""
    collected = collect_flutter_plugin_deps(ctx.attr.deps)
    return [
        DefaultInfo(),
        _DirectPluginsInfo(plugins = collected.all_plugins),
    ]

_graph_collector = rule(
    implementation = _graph_collector_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "Collector fixture simulating flutter_application plugin collection.",
)

def _deps_graph_direct_test_impl(ctx):
    """Verifies direct mark setting from application deps and library deps."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    plugins = target[_DirectPluginsInfo].plugins
    by_name = {p.name: getattr(p, "direct", False) for p in plugins}

    # Plugin in application's deps is direct
    asserts.true(env, by_name.get("plugin_direct", False), "plugin_direct in app deps should be direct")

    # Plugin in first-level library's deps is direct
    asserts.true(env, by_name.get("lib_direct_plugin", False), "lib_direct_plugin should be direct")

    # Plugin reached only through another library's dependency is NOT direct
    asserts.false(env, by_name.get("deep_plugin", True), "deep_plugin through another library should not be direct")

    # Plugin reached through a plugin's dependency is NOT direct
    asserts.false(env, by_name.get("plugin_child", True), "plugin_child through plugin deps should not be direct")
    return analysistest.end(env)

_deps_graph_direct_test = analysistest.make(_deps_graph_direct_test_impl)

_t0_test = unittest.make(_default_only_test_impl)
_t1_test = unittest.make(_default_replaced_by_app_chosen_test_impl)
_t2_test = unittest.make(_platform_without_entry_test_impl)
_t3_test = unittest.make(_order_preserved_test_impl)
_t4_test = unittest.make(_empty_list_test_impl)
_t5_test = unittest.make(_untouched_plugins_test_impl)
_t6_test = unittest.make(_two_alternatives_one_direct_test_impl)
_t7_test = unittest.make(_scenario_s1_test_impl)
_t8_test = unittest.make(_scenario_s2_test_impl)
_t9_test = unittest.make(_scenario_s3_test_impl)
_t10_test = unittest.make(_dedup_preserves_direct_test_impl)

def plugin_federation_test_suite(name):
    """Test suite entry point for plugin federation unit and analysis tests.

    Args:
        name: Name of the test suite.
    """
    _conflict_target(
        name = name + "_conflict_fixture",
        tags = ["manual"],
    )
    _two_implementations_refused_test(
        name = name + "_two_implementations_refused",
        target_under_test = ":" + name + "_conflict_fixture",
    )
    _scenario_s4_target(
        name = name + "_scenario_s4_fixture",
        tags = ["manual"],
    )
    _scenario_s4_test(
        name = name + "_scenario_s4",
        target_under_test = ":" + name + "_scenario_s4_fixture",
    )

    _absent_default_target(
        name = name + "_absent_default_fixture",
        tags = ["manual"],
    )
    _absent_default_refused_test(
        name = name + "_absent_default_refused",
        target_under_test = ":" + name + "_absent_default_fixture",
    )

    # Fixture targets for graph direct tests
    _mock_plugin_node(
        name = name + "_plugin_child",
        plugin_name = "plugin_child",
        tags = ["manual"],
    )
    _mock_plugin_node(
        name = name + "_plugin_direct",
        plugin_name = "plugin_direct",
        deps = [":" + name + "_plugin_child"],
        tags = ["manual"],
    )
    _mock_plugin_node(
        name = name + "_deep_plugin",
        plugin_name = "deep_plugin",
        tags = ["manual"],
    )
    _mock_library_node(
        name = name + "_deep_lib",
        deps = [":" + name + "_deep_plugin"],
        tags = ["manual"],
    )
    _mock_plugin_node(
        name = name + "_lib_direct_plugin",
        plugin_name = "lib_direct_plugin",
        tags = ["manual"],
    )
    _mock_library_node(
        name = name + "_first_level_lib",
        deps = [":" + name + "_lib_direct_plugin", ":" + name + "_deep_lib"],
        tags = ["manual"],
    )
    _graph_collector(
        name = name + "_collector_fixture",
        deps = [":" + name + "_plugin_direct", ":" + name + "_first_level_lib"],
        tags = ["manual"],
    )
    _deps_graph_direct_test(
        name = name + "_deps_graph_direct",
        target_under_test = ":" + name + "_collector_fixture",
    )

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
        _t8_test,
        _t9_test,
        _t10_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_two_implementations_refused",
            ":" + name + "_scenario_s4",
            ":" + name + "_absent_default_refused",
            ":" + name + "_deps_graph_direct",
        ],
    )
