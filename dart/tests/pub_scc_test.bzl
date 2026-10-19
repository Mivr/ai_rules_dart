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

# buildifier: disable=bzl-visibility
load("//dart/pub/private:scc.bzl", "compute_sccs")
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

_t0_test = unittest.make(_two_node_cycle_test_impl)
_t1_test = unittest.make(_three_node_cycle_test_impl)
_t2_test = unittest.make(_two_disjoint_cycles_test_impl)
_t3_test = unittest.make(_cycle_with_acyclic_tail_test_impl)
_t4_test = unittest.make(_acyclic_graph_test_impl)
_t5_test = unittest.make(_self_edge_ignored_test_impl)
_t6_test = unittest.make(_unknown_dep_ignored_test_impl)
_t7_test = unittest.make(_empty_graph_test_impl)
_t8_test = unittest.make(_deterministic_test_impl)

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
    )
