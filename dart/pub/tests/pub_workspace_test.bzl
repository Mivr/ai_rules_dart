"""Unit tests for the pub workspace member checks in `pub_workspace.bzl`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub/private:pub_workspace.bzl", "pub_workspace_error")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

_ROOT = "name: root\nworkspace:\n  - a\n  - b\n"
_A = "name: a\nresolution: workspace\n"
_B = "name: b\nresolution: workspace\n"
_LA = "//a:pubspec.yaml"
_LB = "//b:pubspec.yaml"

def _ok_members():
    return {_LA: _A, _LB: _B}

def _valid_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, pub_workspace_error(_ROOT, _ok_members(), "", ["collection"], ["path"]))
    return unittest.end(env)

def _empty_members_unchecked_test_impl(ctx):
    env = unittest.begin(ctx)

    # Not even a root pubspec that would fail to parse is read.
    asserts.equals(env, None, pub_workspace_error("{{{ not yaml", {}))
    return unittest.end(env)

def _missing_resolution_test_impl(ctx):
    env = unittest.begin(ctx)
    members = {_LA: _A, _LB: "name: b\n"}
    asserts.equals(
        env,
        "member //b:pubspec.yaml: its pubspec.yaml is missing `resolution: workspace`",
        pub_workspace_error(_ROOT, members),
    )
    return unittest.end(env)

def _other_resolution_test_impl(ctx):
    env = unittest.begin(ctx)
    members = {_LA: "name: a\nresolution: local\n", _LB: _B}
    asserts.equals(
        env,
        "member //a:pubspec.yaml: its pubspec.yaml sets `resolution: local`, not `resolution: workspace`",
        pub_workspace_error(_ROOT, members),
    )
    return unittest.end(env)

def _not_listed_test_impl(ctx):
    env = unittest.begin(ctx)
    members = {"//c:pubspec.yaml": "name: c\nresolution: workspace\n"}
    asserts.equals(
        env,
        "member //c:pubspec.yaml: its directory \"c\" is not listed in the root pubspec.yaml `workspace:`",
        pub_workspace_error(_ROOT, members),
    )
    return unittest.end(env)

def _no_workspace_list_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "member //a:pubspec.yaml: the root pubspec.yaml has no `workspace:` list",
        pub_workspace_error("name: root\n", {_LA: _A}),
    )
    return unittest.end(env)

def _error_names_only_the_failing_member_test_impl(ctx):
    env = unittest.begin(ctx)
    error = pub_workspace_error(_ROOT, {_LA: _A, _LB: "name: b\n"})
    asserts.false(env, "//a:" in error)
    return unittest.end(env)

def _nested_member_test_impl(ctx):
    env = unittest.begin(ctx)
    root = "name: root\nworkspace:\n  - pkgs/a/\n  - ./b\n"
    members = {"//app/pkgs/a:pubspec.yaml": _A, "//app/b:pubspec.yaml": _B}
    asserts.equals(env, None, pub_workspace_error(root, members, "app"))
    return unittest.end(env)

def _outside_root_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "member //other/a:pubspec.yaml: its pubspec.yaml is outside the root's directory \"app\"",
        pub_workspace_error(_ROOT, {"//other/a:pubspec.yaml": _A}, "app"),
    )

    # A sibling directory sharing the root's name as a prefix is outside too.
    asserts.true(env, pub_workspace_error(_ROOT, {"//apple/a:pubspec.yaml": _A}, "app") != None)
    return unittest.end(env)

def _locked_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "member //a:pubspec.yaml: its name \"a\" is also a package in the lock",
        pub_workspace_error(_ROOT, _ok_members(), "", ["a", "path"]),
    )
    return unittest.end(env)

def _declared_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "member //b:pubspec.yaml: its name \"b\" is also declared with pub.package()",
        pub_workspace_error(_ROOT, _ok_members(), "", [], ["b"]),
    )
    return unittest.end(env)

_t0_test = unittest.make(_valid_test_impl)
_t1_test = unittest.make(_empty_members_unchecked_test_impl)
_t2_test = unittest.make(_missing_resolution_test_impl)
_t3_test = unittest.make(_other_resolution_test_impl)
_t4_test = unittest.make(_not_listed_test_impl)
_t5_test = unittest.make(_no_workspace_list_test_impl)
_t6_test = unittest.make(_error_names_only_the_failing_member_test_impl)
_t7_test = unittest.make(_nested_member_test_impl)
_t8_test = unittest.make(_outside_root_test_impl)
_t9_test = unittest.make(_locked_name_test_impl)
_t10_test = unittest.make(_declared_name_test_impl)

def pub_workspace_test_suite(name):
    """Declares the pub workspace check tests.

    Args:
      name: Name of the generated test suite.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test)
