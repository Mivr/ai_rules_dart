"""Unit tests for the pub SCC computation (`dart/pub/private/scc.bzl`).

Each cycle shape the hub merge must handle gets a case: a two-node cycle
(`dio` and `dio_web_adapter`), a three-node cycle, two disjoint cycles, and a
cycle with an acyclic tail reaching into it. The acyclic case pins the
no-merge contract — every package stays a singleton, so hub output is
unchanged. Determinism and edge filtering (self-edges, unknown names) are
pinned too, because the merged repository names are derived from the
components.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub_content")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "make_dart_package_member_build_content", "make_scc_merged_build_content")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:scc.bzl", "compute_sccs", "normalize_pub_dep", "pubspec_dep_graph", "rewrite_vanished_spoke", "scc_repo_name")
load(":small_suite.bzl", "small_unittest_suite")

def _two_node_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["dio", "dio_web_adapter"], ["meta"]],
        compute_sccs({
            "dio": ["dio_web_adapter", "meta"],
            "dio_web_adapter": ["dio", "meta"],
            "meta": [],
        }),
    )
    return unittest.end(env)

def _three_node_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["aaa", "bbb", "ccc"]],
        compute_sccs({
            "aaa": ["bbb"],
            "bbb": ["ccc"],
            "ccc": ["aaa"],
        }),
    )
    return unittest.end(env)

def _two_disjoint_cycles_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["aaa", "bbb"], ["xxx", "yyy"]],
        compute_sccs({
            "aaa": ["bbb"],
            "bbb": ["aaa"],
            "xxx": ["yyy"],
            "yyy": ["xxx"],
        }),
    )
    return unittest.end(env)

def _cycle_with_acyclic_tail_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["dio", "dio_web_adapter"], ["my_app"], ["path"]],
        compute_sccs({
            # `my_app` depends on the cycle but nothing depends back on it,
            # so it stays a singleton spoke.
            "my_app": ["dio", "path"],
            "dio": ["dio_web_adapter", "path"],
            "dio_web_adapter": ["dio"],
            "path": [],
        }),
    )
    return unittest.end(env)

def _acyclic_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["collection"], ["file"], ["meta"], ["path"]],
        compute_sccs({
            "file": ["path"],
            "collection": [],
            "path": ["meta"],
            "meta": [],
        }),
    )
    return unittest.end(env)

def _self_edge_ignored_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["aaa"], ["bbb"]],
        compute_sccs({
            "aaa": ["aaa", "bbb"],
            "bbb": [],
        }),
    )
    return unittest.end(env)

def _unknown_dep_ignored_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [["aaa"]],
        compute_sccs({
            # `flutter` is an SDK package: outside the lock, so outside the graph.
            "aaa": ["flutter", "sdk_only"],
        }),
    )
    return unittest.end(env)

def _empty_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], compute_sccs({}))
    return unittest.end(env)

def _deterministic_test_impl(ctx):
    env = unittest.begin(ctx)
    first = compute_sccs({
        "my_app": ["dio", "path"],
        "dio_web_adapter": ["dio"],
        "path": [],
        "dio": ["dio_web_adapter", "path"],
    })
    second = compute_sccs({
        "dio": ["path", "dio_web_adapter"],
        "path": [],
        "my_app": ["path", "dio"],
        "dio_web_adapter": ["dio"],
    })
    asserts.equals(env, first, second)
    asserts.equals(
        env,
        [["dio", "dio_web_adapter"], ["my_app"], ["path"]],
        first,
    )
    return unittest.end(env)

def _normalize_pub_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    hubs = ["pub_deps"]
    prefixes = ["dart_pub"]
    asserts.equals(env, "foo", normalize_pub_dep("foo", hubs, prefixes))
    asserts.equals(env, "foo", normalize_pub_dep("dart_pub__foo", hubs, prefixes))
    asserts.equals(env, "foo", normalize_pub_dep("@dart_pub__foo//:foo", hubs, prefixes))
    asserts.equals(env, "foo", normalize_pub_dep("@pub_deps//:foo", hubs, prefixes))
    asserts.equals(env, "foo", normalize_pub_dep("pub_deps//:foo", hubs, prefixes))
    asserts.equals(env, "", normalize_pub_dep("@other//:foo", hubs, prefixes))
    asserts.equals(env, "", normalize_pub_dep("@other_repo", hubs, prefixes))
    asserts.equals(env, "other_repo", normalize_pub_dep("other_repo", hubs, prefixes))
    return unittest.end(env)

_DIO_PUBSPEC = """\
name: dio
environment:
  sdk: ">=2.18.0 <4.0.0"
dependencies:
  async: ^2.8.2
  dio_web_adapter: ">=1.1.0 <3.0.0"
  meta: ^1.5.0
"""

_ADAPTER_PUBSPEC = """\
name: dio_web_adapter
environment:
  sdk: ^3.3.0
dependencies:
  dio: ^5.8.0
  meta: ^1.5.0
"""

def _pubspec_dep_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = pubspec_dep_graph(
        {
            "dio": _DIO_PUBSPEC,
            "dio_web_adapter": _ADAPTER_PUBSPEC,
            "meta": "name: meta\n",
        },
        {},
        ["dio", "dio_web_adapter", "meta"],
        ["pub_deps"],
        ["dart_pub"],
    )
    asserts.equals(
        env,
        {
            "dio": ["dio_web_adapter", "meta"],
            "dio_web_adapter": ["dio", "meta"],
            "meta": [],
        },
        graph,
    )

    # Unknown and SDK-only deps never enter the graph, and explicit deps are
    # normalized from repo names.
    explicit_graph = pubspec_dep_graph(
        {"aaa": "name: aaa\ndependencies:\n  flutter: sdk\n  bbb: any\n"},
        {"exp": ["dart_pub__aaa", "@pub_deps//:exp"]},
        ["aaa", "bbb", "exp"],
        ["pub_deps"],
        ["dart_pub"],
    )
    asserts.equals(
        env,
        {"aaa": ["bbb"], "exp": ["aaa"]},
        explicit_graph,
    )
    return unittest.end(env)

def _scc_repo_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "dart_pub__scc__dio__dio_web_adapter",
        scc_repo_name("dart_pub", ["dio", "dio_web_adapter"]),
    )
    asserts.equals(
        env,
        "my_hub__scc__aaa__bbb",
        scc_repo_name("my_hub", ["aaa", "bbb"]),
    )
    return unittest.end(env)

def _rewrite_vanished_spoke_test_impl(ctx):
    env = unittest.begin(ctx)
    vanished = {"dart_pub__dio": "dart_pub__scc__dio__dio_web_adapter"}
    asserts.equals(
        env,
        "dart_pub__scc__dio__dio_web_adapter",
        rewrite_vanished_spoke("dart_pub__dio", vanished),
    )
    asserts.equals(
        env,
        "@dart_pub__scc__dio__dio_web_adapter//:dio",
        rewrite_vanished_spoke("@dart_pub__dio//:dio", vanished),
    )
    asserts.equals(env, "path", rewrite_vanished_spoke("path", vanished))
    asserts.equals(
        env,
        "@pub_deps//:dio",
        rewrite_vanished_spoke("@pub_deps//:dio", vanished),
    )
    return unittest.end(env)

def _hub_content_acyclic_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        """\
alias(
    name = "collection",
    actual = "@dart_pub__collection//:collection",
    visibility = ["//visibility:public"],
)

alias(
    name = "file",
    actual = "@dart_pub__file//:file",
    visibility = ["//visibility:public"],
)

alias(
    name = "path",
    actual = "@path//:path",
    visibility = ["//visibility:public"],
)
""",
        pub_lock_hub_content(
            ["collection", "file", "path"],
            ["path"],
            "dart_pub",
        ),
    )
    return unittest.end(env)

def _hub_content_scc_test_impl(ctx):
    env = unittest.begin(ctx)
    content = pub_lock_hub_content(
        ["dio", "dio_web_adapter", "meta"],
        [],
        "dart_pub",
        {"dio": "@dart_pub__scc__dio__dio_web_adapter//:dio", "dio_web_adapter": "@dart_pub__scc__dio__dio_web_adapter//:dio_web_adapter"},
    )
    asserts.true(
        env,
        'actual = "@dart_pub__scc__dio__dio_web_adapter//:dio"' in content,
        "dio aliases to the merged repository: %s" % content,
    )
    asserts.true(
        env,
        'actual = "@dart_pub__scc__dio__dio_web_adapter//:dio_web_adapter"' in content,
        "dio_web_adapter aliases to the merged repository: %s" % content,
    )
    asserts.true(
        env,
        'actual = "@dart_pub__meta//:meta"' in content,
        "acyclic packages still alias to spokes: %s" % content,
    )
    return unittest.end(env)

def _member_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_dart_package_member_build_content(
        name = "dio",
        language_version = "2.18",
        version = "5.11.1",
    )
    asserts.true(env, 'load("@rules_dart//dart:defs.bzl", "dart_package_member")' in content)
    asserts.true(env, "dart_package_member(" in content)
    asserts.true(env, 'package_name = "dio"' in content)
    asserts.true(env, 'language_version = "2.18"' in content)
    asserts.true(env, 'version = "5.11.1"' in content)
    asserts.true(env, "dart_test_package" not in content)
    return unittest.end(env)

def _member_test_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_dart_package_member_build_content(
        name = "test",
        language_version = "3.0",
        version = "1.25.0",
        merged_label = "//:merged",
    )
    asserts.true(env, "dart_test_package(" in content)
    asserts.true(env, 'library = "//:merged"' in content)
    asserts.true(env, 'deps = ["//:merged"]' in content)
    return unittest.end(env)

def _merged_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_scc_merged_build_content(
        members = ["dio", "dio_web_adapter"],
        dep_labels = ["@dart_pub__meta//:meta", "@path//:path"],
        repo_name = "dart_pub__scc__dio__dio_web_adapter",
    )
    asserts.true(env, "dart_library(" in content)
    asserts.true(env, '"//dio:dio"' in content)
    asserts.true(env, '"//dio_web_adapter:dio_web_adapter"' in content)
    asserts.true(env, '"@dart_pub__meta//:meta"' in content)
    asserts.true(env, '"@path//:path"' in content)
    asserts.true(env, 'name = "dio"' in content)
    asserts.true(env, 'name = "dio_web_adapter"' in content)
    asserts.true(env, 'name = "dart_pub__scc__dio__dio_web_adapter"' in content)
    asserts.true(env, "actual = \":merged\"" in content)
    # Edges leaving the cycle are the merged target's deps, in order.
    deps_at = content.find("deps = [")
    meta_at = content.find('"@dart_pub__meta//:meta"')
    asserts.true(env, deps_at != -1 and deps_at < meta_at)
    return unittest.end(env)

_t0_test = unittest.make(_two_node_cycle_test_impl)
_t1_test = unittest.make(_three_node_cycle_test_impl)
_t2_test = unittest.make(_two_disjoint_cycles_test_impl)
_t3_test = unittest.make(_cycle_with_acyclic_tail_test_impl)
_t4_test = unittest.make(_acyclic_graph_test_impl)
_t5_test = unittest.make(_self_edge_ignored_test_impl)
_t6_test = unittest.make(_unknown_dep_ignored_test_impl)
_t7_test = unittest.make(_empty_graph_test_impl)
_t8_test = unittest.make(_deterministic_test_impl)
_t9_test = unittest.make(_normalize_pub_dep_test_impl)
_t10_test = unittest.make(_pubspec_dep_graph_test_impl)
_t11_test = unittest.make(_scc_repo_name_test_impl)
_t12_test = unittest.make(_rewrite_vanished_spoke_test_impl)
_t13_test = unittest.make(_hub_content_acyclic_test_impl)
_t14_test = unittest.make(_hub_content_scc_test_impl)
_t15_test = unittest.make(_member_content_test_impl)
_t16_test = unittest.make(_member_test_content_test_impl)
_t17_test = unittest.make(_merged_content_test_impl)

def pub_scc_test_suite(name):
    small_unittest_suite(
        name,
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
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
    )
