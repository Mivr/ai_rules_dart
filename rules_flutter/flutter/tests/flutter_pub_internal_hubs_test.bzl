"""Unit tests for flutter.pub internal hub handling and lazy planning."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "@rules_dart//dart/pub:pub_scc.bzl",
    "PARSER_SOURCE_LABELS",
    "parser_schema",
)
load(
    "//flutter/private:flutter_pub_scc.bzl",
    "hosted_fact_key",
)
load(
    "//flutter/private:flutter_pub_scc_plan.bzl",
    "plan_hub_sccs",
)
load(
    "//flutter/private:tool_deps_extension.bzl",
    "register_tool_pub_hub",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _fail_called(method):
    """Fails immediately if an unexpected module_ctx method is invoked."""
    fail(method + " called on mock module_ctx")

def _mock_error_ctx():
    """Returns a mock module_ctx whose download, execute, and read fail if called."""
    return struct(
        download = lambda _url = "", output = "", sha256 = "": _fail_called("download"),
        execute = lambda _args = []: _fail_called("execute"),
        read = lambda _label = "", watch = "no": _fail_called("read"),
    )

def _hosted_entry(name, version, sha_char):
    """Builds a minimal hosted package lock entry for unit tests."""
    return {
        "description": {
            "name": name,
            "sha256": sha_char * 64,
            "url": "https://pub.dev",
        },
        "source": "hosted",
        "version": version,
    }

def _plan_internal_hub(mock_ctx, hub_name, lock_label, hosted, facts_state):
    """Plans one internal hub with sorted package names."""
    tag = struct(
        cycle_breaks = {},
        lock = lock_label,
        name = hub_name,
    )
    return plan_hub_sccs(
        mock_ctx,
        hub_name,
        hosted,
        {},
        sorted(hosted.keys()),
        tag,
        facts_state,
    )

def _assert_lazy_singleton_plan(env, plan, expected_singletons):
    """Asserts that a plan has only lazy singletons and no SCC or planned_deps metadata."""
    asserts.equals(env, expected_singletons, plan.singletons)
    asserts.equals(env, {}, plan.merged)
    asserts.equals(env, {}, plan.scc_targets)
    asserts.equals(env, {}, plan.planned_deps)

def _dev_tool_and_gen_l10n_internal_plan_test_impl(ctx):
    """Internal hubs dev_tool_deps and gen_l10n_deps plan lazily without touches or facts."""
    env = unittest.begin(ctx)
    mock_ctx = _mock_error_ctx()
    facts_state = struct(facts = {}, recorded = [])

    dev_hosted = {
        "args": _hosted_entry("args", "2.5.0", "1"),
        "path": _hosted_entry("path", "1.9.0", "2"),
    }
    dev_plan = _plan_internal_hub(
        mock_ctx,
        "dev_tool_deps",
        Label("//tools/dev_tool:pubspec.lock"),
        dev_hosted,
        facts_state,
    )
    _assert_lazy_singleton_plan(env, dev_plan, ["args", "path"])
    asserts.equals(env, [], facts_state.recorded)
    asserts.equals(env, {}, facts_state.facts)

    gen_hosted = {
        "intl": _hosted_entry("intl", "0.19.0", "3"),
        "meta": _hosted_entry("meta", "1.15.0", "4"),
    }
    gen_plan = _plan_internal_hub(
        mock_ctx,
        "gen_l10n_deps",
        Label("//flutter/private/gen_l10n:pubspec.lock"),
        gen_hosted,
        facts_state,
    )
    _assert_lazy_singleton_plan(env, gen_plan, ["intl", "meta"])
    asserts.equals(env, [], facts_state.recorded)
    asserts.equals(env, {}, facts_state.facts)

    return unittest.end(env)

def _two_cycle_consumer_fixture():
    """Creates a cached 2-cycle hosted consumer fixture."""
    schema = parser_schema(["# parser source" for _ in PARSER_SOURCE_LABELS])
    key_a = hosted_fact_key("cycle_a", "1.0.0", "a" * 64, schema)
    key_b = hosted_fact_key("cycle_b", "1.0.0", "b" * 64, schema)
    consumer_ctx = struct(
        facts = {
            key_a: ["cycle_b"],
            key_b: ["cycle_a"],
        },
        read = lambda _label, watch = "no": "# parser source",
    )
    hosted = {
        "cycle_a": _hosted_entry("cycle_a", "1.0.0", "a"),
        "cycle_b": _hosted_entry("cycle_b", "1.0.0", "b"),
    }
    return struct(
        ctx = consumer_ctx,
        fact_keys = sorted([key_a, key_b]),
        hosted = hosted,
    )

def _assert_foreign_same_name_merges(env, fixture):
    """Verifies a hub named dev_tool_deps in another module still runs consumer SCC planning."""
    foreign_state = struct(facts = {}, recorded = [])
    foreign_tag = struct(
        cycle_breaks = {},
        lock = Label("@@consumer_workspace//:pubspec.lock"),
        name = "dev_tool_deps",
    )
    plan = plan_hub_sccs(
        fixture.ctx,
        "dev_tool_deps",
        fixture.hosted,
        {},
        ["cycle_a", "cycle_b"],
        foreign_tag,
        foreign_state,
    )
    expected_repo = "dev_tool_deps__scc__cycle_a__cycle_b"
    asserts.equals(env, [True], foreign_state.recorded)
    asserts.equals(env, fixture.fact_keys, sorted(foreign_state.facts.keys()))
    asserts.equals(env, {expected_repo: ["cycle_a", "cycle_b"]}, plan.merged)

def _internal_and_consumer_hub_plan_test_impl(ctx):
    """Internal hubs leave facts clean while consumer hubs record facts and merge SCCs."""
    env = unittest.begin(ctx)
    facts_state = struct(facts = {}, recorded = [])
    mock_ctx = _mock_error_ctx()

    dev_plan = _plan_internal_hub(
        mock_ctx,
        "dev_tool_deps",
        Label("//tools/dev_tool:pubspec.lock"),
        {
            "args": _hosted_entry("args", "2.5.0", "1"),
            "path": _hosted_entry("path", "1.9.0", "2"),
        },
        facts_state,
    )
    gen_plan = _plan_internal_hub(
        mock_ctx,
        "gen_l10n_deps",
        Label("//flutter/private/gen_l10n:pubspec.lock"),
        {
            "intl": _hosted_entry("intl", "0.19.0", "3"),
            "meta": _hosted_entry("meta", "1.15.0", "4"),
        },
        facts_state,
    )

    fixture = _two_cycle_consumer_fixture()
    consumer_tag = struct(
        cycle_breaks = {},
        lock = Label("@@consumer_workspace//:pubspec.lock"),
        name = "consumer_deps",
    )
    consumer_plan = plan_hub_sccs(
        fixture.ctx,
        "consumer_deps",
        fixture.hosted,
        {},
        ["cycle_a", "cycle_b"],
        consumer_tag,
        facts_state,
    )

    expected_repo = "consumer_deps__scc__cycle_a__cycle_b"
    asserts.equals(env, [True], facts_state.recorded)
    asserts.equals(env, fixture.fact_keys, sorted(facts_state.facts.keys()))
    asserts.equals(env, {expected_repo: ["cycle_a", "cycle_b"]}, consumer_plan.merged)
    asserts.equals(
        env,
        {
            "cycle_a": "@" + expected_repo + "//:cycle_a",
            "cycle_b": "@" + expected_repo + "//:cycle_b",
        },
        consumer_plan.scc_targets,
    )
    asserts.equals(
        env,
        {"cycle_a": ["cycle_b"], "cycle_b": ["cycle_a"]},
        consumer_plan.planned_deps,
    )
    _assert_lazy_singleton_plan(env, dev_plan, ["args", "path"])
    _assert_lazy_singleton_plan(env, gen_plan, ["intl", "meta"])
    _assert_foreign_same_name_merges(env, fixture)

    return unittest.end(env)

def _register_tool_pub_hub_test_impl(ctx):
    """register_tool_pub_hub emits the hub and pure-Dart hosted spokes without android spokes."""
    env = unittest.begin(ctx)
    lock_yaml = "\n".join([
        "packages:",
        "  intl:",
        "    dependency: \"direct main\"",
        "    description:",
        "      name: intl",
        "      sha256: \"" + ("3" * 64) + "\"",
        "      url: \"https://pub.dev\"",
        "    source: hosted",
        "    version: \"0.20.3\"",
        "  meta:",
        "    dependency: transitive",
        "    description:",
        "      name: meta",
        "      sha256: \"" + ("4" * 64) + "\"",
        "      url: \"https://pub.dev\"",
        "    source: hosted",
        "    version: \"1.18.3\"",
    ])
    hubs = []
    spokes = []
    lock_label = Label("//flutter/private/gen_l10n:pubspec.lock")
    mock_ctx = struct(read = lambda _label: lock_yaml)
    pub_tag = struct(name = "gen_l10n_deps", lock = lock_label)

    pkgs = register_tool_pub_hub(
        mock_ctx,
        pub_tag,
        hub_rule = lambda **kwargs: hubs.append(kwargs),
        spoke_rule = lambda **kwargs: spokes.append(kwargs),
    )

    asserts.equals(env, ["intl", "meta"], pkgs)
    asserts.equals(env, 1, len(hubs))
    asserts.equals(env, "gen_l10n_deps", hubs[0]["name"])
    asserts.equals(env, ["intl", "meta"], hubs[0]["packages"])
    asserts.equals(env, 2, len(spokes))
    asserts.equals(env, "gen_l10n_deps__intl", spokes[0]["name"])
    asserts.equals(env, "0.20.3", spokes[0]["version"])
    asserts.equals(env, "3" * 64, spokes[0]["sha256"])
    asserts.equals(env, "gen_l10n_deps__meta", spokes[1]["name"])
    asserts.equals(env, lock_label, spokes[1]["pubspec_lock"])
    return unittest.end(env)

_dev_tool_and_gen_l10n_internal_plan_test = unittest.make(_dev_tool_and_gen_l10n_internal_plan_test_impl)
_internal_and_consumer_hub_plan_test = unittest.make(_internal_and_consumer_hub_plan_test_impl)
_register_tool_pub_hub_test = unittest.make(_register_tool_pub_hub_test_impl)

def flutter_pub_internal_hubs_test_suite(name):
    """Defines the flutter.pub internal hubs unit test suite."""
    small_unittest_suite(
        name,
        _dev_tool_and_gen_l10n_internal_plan_test,
        _internal_and_consumer_hub_plan_test,
        _register_tool_pub_hub_test,
    )
