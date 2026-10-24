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
load("//dart/pub:extensions.bzl", "plan_scope_sccs", "resolve_pub_packages", "scc_member_entries")
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
    asserts.true(env, "dart_package_member(" in content)
    asserts.true(env, 'name = "test_library"' in content)
    asserts.true(env, 'package_name = "test"' in content)
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

def _merged_test_member_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_scc_merged_build_content(
        members = ["foo", "test"],
        dep_labels = [],
        repo_name = "dart_pub__scc__foo__test",
    )
    asserts.true(env, '"//foo:foo"' in content)
    asserts.true(env, '"//test:test_library"' in content)
    asserts.true(env, 'name = "test",\n    actual = "//test:test"' in content)
    asserts.true(env, 'name = "foo",\n    actual = ":merged"' in content)
    return unittest.end(env)

def _plan_scope_sccs_test_impl(ctx):
    env = unittest.begin(ctx)
    plan = plan_scope_sccs(
        ["dio", "dio_web_adapter", "meta", "my_app"],
        {},
        ["pub_deps"],
        "dart_pub",
        {
            "dio": _DIO_PUBSPEC,
            "dio_web_adapter": _ADAPTER_PUBSPEC,
            "meta": "name: meta\n",
            "my_app": "name: my_app\ndependencies:\n  dio: any\n",
        },
    )
    asserts.equals(
        env,
        {"dio": "dart_pub__scc__dio__dio_web_adapter", "dio_web_adapter": "dart_pub__scc__dio__dio_web_adapter"},
        plan.members,
    )
    asserts.equals(
        env,
        {"dart_pub__scc__dio__dio_web_adapter": ["dio", "dio_web_adapter"]},
        plan.merged,
    )
    return unittest.end(env)

def _plan_scope_sccs_isolated_test_impl(ctx):
    env = unittest.begin(ctx)
    plan = plan_scope_sccs(
        ["aaa", "bbb"],
        {},
        ["tool_deps"],
        "tool_deps",
        {
            "aaa": "name: aaa\ndependencies:\n  bbb: any\n",
            "bbb": "name: bbb\ndependencies:\n  aaa: any\n",
        },
    )
    asserts.equals(
        env,
        {"aaa": "tool_deps__scc__aaa__bbb", "bbb": "tool_deps__scc__aaa__bbb"},
        plan.members,
    )
    return unittest.end(env)

def _plan_scope_sccs_explicit_left_alone_test_impl(ctx):
    env = unittest.begin(ctx)
    plan = plan_scope_sccs(
        ["aaa", "exp"],
        {"exp": ["aaa"]},
        ["pub_deps"],
        "dart_pub",
        {
            "aaa": "name: aaa\ndependencies:\n  exp: any\n",
        },
    )
    asserts.equals(env, {}, plan.members)
    asserts.equals(env, {}, plan.merged)
    return unittest.end(env)

def _git_cycle_in_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = pubspec_dep_graph(
        {
            "hosted_a": "name: hosted_a\ndependencies:\n  git_b: any\n",
            "git_b": "name: git_b\ndependencies:\n  hosted_a: any\n",
        },
        {},
        ["hosted_a", "git_b"],
        ["pub_deps"],
        ["dart_pub"],
    )
    asserts.equals(
        env,
        [["git_b", "hosted_a"]],
        compute_sccs(graph),
    )
    return unittest.end(env)

def _scc_member_entries_test_impl(ctx):
    env = unittest.begin(ctx)
    entries = scc_member_entries(
        ["git_b", "hosted_a"],
        {"hosted_a": struct(version = "1.0.0", sha256 = "s", url = "https://pub.dev")},
        {"git_b": struct(version = "1.0.0", url = "https://example.com/repo.git", resolved_ref = "deadbeef", path = "pkgs/git_b")},
    )
    asserts.equals(env, 2, len(entries))
    asserts.equals(env, "git", entries[0].source)
    asserts.equals(env, "git_b", entries[0].name)
    asserts.equals(env, "deadbeef", entries[0].resolved_ref)
    asserts.equals(env, "pkgs/git_b", entries[0].path)
    asserts.equals(env, "hosted", entries[1].source)
    asserts.equals(env, "hosted_a", entries[1].name)
    asserts.false(
        env,
        hasattr(entries[1], "scanned_sha256"),
        "a hosted member entry carries no planning verdict: the merged " +
        "repository always scans the member archive it downloads",
    )
    return unittest.end(env)

_HOSTED_CHARCODE = {
    "source": "hosted",
    "version": "1.4.0",
    "dependency": "transitive",
    "description": {
        "name": "charcode",
        "sha256": "fb0f1107cac15a5ea6ef0a6ef71a807b9e4267c713bb93e00e92d737cc8dbd8a",
        "url": "https://pub.dev",
    },
}

_HOSTED_META = {
    "source": "hosted",
    "version": "1.19.0",
    "dependency": "transitive",
    "description": {
        "name": "meta",
        "sha256": "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9",
        "url": "https://pub.dev",
    },
}

_GIT_MYAPP = {
    "source": "git",
    "version": "1.0.0",
    "dependency": "direct main",
    "description": {
        "url": "https://example.com/mono.git",
        "resolved-ref": "1e4987ef30c1a6add32df283cefb81e798b4bed9",
        "path": ".",
    },
}

_GIT_CHARCODE = {
    "source": "git",
    "version": "1.4.0",
    "dependency": "transitive",
    "description": {
        "url": "https://example.com/mono.git",
        "resolved-ref": "1e4987ef30c1a6add32df283cefb81e798b4bed9",
        "path": "pkgs/charcode",
    },
}

def _git_shadows_hosted_test_impl(ctx):
    env = unittest.begin(ctx)

    # One lock hosts charcode while another lock carries it as git (a
    # monorepo subdirectory); the union must plan charcode once, from git.
    # Without the shadowing the extension generates dart_pub__charcode twice
    # and evaluation fails with "already generated by this module extension".
    result = resolve_pub_packages(
        [],
        [
            struct(
                name = "host_hub",
                lock = "//:host.lock",
                packages = {"charcode": _HOSTED_CHARCODE, "meta": _HOSTED_META},
                on_version_conflict = "error",
                isolated = False,
            ),
            struct(
                name = "git_hub",
                lock = "//:git.lock",
                packages = {"myapp": _GIT_MYAPP, "charcode": _GIT_CHARCODE},
                on_version_conflict = "error",
                isolated = False,
            ),
        ],
    )
    asserts.equals(env, None, result.error)
    asserts.false(env, "charcode" in result.resolved, "hosted charcode yields to the git checkout: %s" % sorted(result.resolved.keys()))
    asserts.true(env, "charcode" in result.resolved_git)
    asserts.equals(env, "pkgs/charcode", result.resolved_git["charcode"].path)
    asserts.true(env, "myapp" in result.resolved_git)
    asserts.true(env, "meta" in result.resolved)
    asserts.true(
        env,
        any(["charcode" in warning for warning in result.warnings]),
        "shadowing warns naming the package: %s" % result.warnings,
    )
    return unittest.end(env)

def _git_shadows_hosted_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    result = resolve_pub_packages(
        [],
        [
            struct(
                name = "host_hub",
                lock = "//:host.lock",
                packages = {"charcode": _HOSTED_CHARCODE},
                on_version_conflict = "error",
                isolated = False,
            ),
            struct(
                name = "git_hub",
                lock = "//:git.lock",
                packages = {"myapp": _GIT_MYAPP, "charcode": _GIT_CHARCODE},
                on_version_conflict = "error",
                isolated = False,
            ),
        ],
    )
    asserts.equals(env, None, result.error)

    # The vendored charcode and the monorepo root depend on each other, so
    # both merge into one repository. The merged member entries must fetch
    # the git checkout, not the hosted tarball the shadowing dropped.
    plan = plan_scope_sccs(
        ["charcode", "myapp"],
        {},
        ["git_hub"],
        "dart_pub",
        {
            "charcode": "name: charcode\ndependencies:\n  myapp: any\n",
            "myapp": "name: myapp\ndependencies:\n  charcode: any\n",
        },
    )
    asserts.equals(env, plan.members["charcode"], plan.members["myapp"])
    entries = scc_member_entries(
        plan.merged[plan.members["charcode"]],
        result.resolved,
        result.resolved_git,
    )
    by_name = {entry.name: entry for entry in entries}
    asserts.equals(env, "git", by_name["charcode"].source)
    asserts.equals(env, "pkgs/charcode", by_name["charcode"].path)
    asserts.equals(env, "git", by_name["myapp"].source)
    return unittest.end(env)

def _git_shadows_hosted_isolated_test_impl(ctx):
    env = unittest.begin(ctx)
    result = resolve_pub_packages(
        [],
        [
            struct(
                name = "tool",
                lock = "//:a.lock",
                packages = {"charcode": _HOSTED_CHARCODE},
                on_version_conflict = "error",
                isolated = True,
            ),
            struct(
                name = "tool",
                lock = "//:b.lock",
                packages = {"myapp": _GIT_MYAPP, "charcode": _GIT_CHARCODE},
                on_version_conflict = "error",
                isolated = True,
            ),
        ],
    )
    asserts.equals(env, None, result.error)
    asserts.false(env, "charcode" in result.isolated_packages["tool"])
    asserts.true(env, "charcode" in result.isolated_git_packages["tool"])
    asserts.true(env, "myapp" in result.isolated_git_packages["tool"])
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
_t18_test = unittest.make(_plan_scope_sccs_test_impl)
_t19_test = unittest.make(_plan_scope_sccs_isolated_test_impl)
_t20_test = unittest.make(_plan_scope_sccs_explicit_left_alone_test_impl)
_t21_test = unittest.make(_merged_test_member_content_test_impl)
_t22_test = unittest.make(_git_cycle_in_graph_test_impl)
_t23_test = unittest.make(_scc_member_entries_test_impl)
_t24_test = unittest.make(_git_shadows_hosted_test_impl)
_t25_test = unittest.make(_git_shadows_hosted_cycle_test_impl)
_t26_test = unittest.make(_git_shadows_hosted_isolated_test_impl)

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
        _t18_test,
        _t19_test,
        _t20_test,
        _t21_test,
        _t22_test,
        _t23_test,
        _t24_test,
        _t25_test,
        _t26_test,
    )
