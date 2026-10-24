"""Unit tests for the pub SCC facts cache (`dart/pub/private/pub_scc_facts.bzl`).

The extension records each planned package's pubspec deps as lockfile facts so
re-evaluations fetch only changed packages. These tests pin the key building
(any change of version, sha256, resolved ref, or path is a miss), the
fetch split (full facts fetch nothing, one bump fetches one, no facts fetch
everything), that the merge plan from facts equals the plan from pubspec
contents on a cyclic graph, that foreign-schema facts are ignored while a
malformed current-schema fact fails naming its key and stale entries are
dropped, and the narrowed scratch check's five decisions.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub:extensions.bzl", "plan_scope_sccs")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_scc_facts.bzl", "contents_from_fact_deps", "fact_deps_error", "git_fact_key", "hosted_fact_key", "lookup_fact_deps", "record_scope_facts", "scratch_pubspec_error", "split_scope_facts")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

_SHA = "fb0f1107cac15a5ea6ef0a6ef71a807b9e4267c713bb93e00e92d737cc8dbd8a"
_OTHER_SHA = "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9"
_REF = "1e4987ef30c1a6add32df283cefb81e798b4bed9"
_OTHER_REF = "2f6098cf40d1b7bdd43ef384dfab82e809c5cee0"

def _hosted(version = "1.4.0", sha256 = _SHA):
    return struct(version = version, sha256 = sha256, url = "https://pub.dev")

def _git(ref = _REF, path = "pkgs/charcode"):
    return struct(version = "1.4.0", url = "https://example.com/mono.git", resolved_ref = ref, path = path)

def _hosted_key_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, hosted_fact_key("meta", "1.19.0", _SHA), hosted_fact_key("meta", "1.19.0", _SHA), "same inputs give the same key")
    asserts.true(env, hosted_fact_key("meta", "1.19.0", _SHA) != hosted_fact_key("meta", "1.20.0", _SHA), "a version bump is a miss")
    asserts.true(env, hosted_fact_key("meta", "1.19.0", _SHA) != hosted_fact_key("meta", "1.19.0", _OTHER_SHA), "a sha256 bump is a miss")
    asserts.true(env, hosted_fact_key("meta", "1.19.0", _SHA) != hosted_fact_key("path", "1.19.0", _SHA), "another package is another key")
    return unittest.end(env)

def _git_key_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, git_fact_key("charcode", _REF, "pkgs/charcode"), git_fact_key("charcode", _REF, "pkgs/charcode"), "same inputs give the same key")
    asserts.true(env, git_fact_key("charcode", _REF, "pkgs/charcode") != git_fact_key("charcode", _OTHER_REF, "pkgs/charcode"), "a ref bump is a miss")
    asserts.true(env, git_fact_key("charcode", _REF, "pkgs/charcode") != git_fact_key("charcode", _REF, "pkgs/other"), "a path move is a miss")
    asserts.true(env, git_fact_key("charcode", _REF, ".") != git_fact_key("charcode", _REF, "pkgs/charcode"), "root and subdirectory paths differ")
    return unittest.end(env)

def _split_full_facts_test_impl(ctx):
    env = unittest.begin(ctx)
    hosted = {"charcode": _hosted(), "meta": _hosted(version = "1.19.0", sha256 = _OTHER_SHA)}
    git_pkgs = {"myapp": struct(version = "1.0.0", url = "https://example.com/mono.git", resolved_ref = _REF, path = ".")}
    facts = {
        hosted_fact_key("charcode", "1.4.0", _SHA): ["myapp"],
        hosted_fact_key("meta", "1.19.0", _OTHER_SHA): [],
        git_fact_key("myapp", _REF, "."): ["charcode"],
    }
    split = split_scope_facts(facts, hosted, git_pkgs)
    asserts.equals(env, {}, split.hosted_miss, "full facts fetch no hosted package")
    asserts.equals(env, {}, split.git_miss, "full facts fetch no git package")
    asserts.equals(env, ["myapp"], split.deps["charcode"])
    asserts.equals(env, [], split.deps["meta"])
    asserts.equals(env, ["charcode"], split.deps["myapp"])
    return unittest.end(env)

def _split_one_bump_test_impl(ctx):
    env = unittest.begin(ctx)
    hosted = {"charcode": _hosted(sha256 = _OTHER_SHA), "meta": _hosted(version = "1.19.0", sha256 = _OTHER_SHA)}
    git_pkgs = {"myapp": struct(version = "1.0.0", url = "https://example.com/mono.git", resolved_ref = _REF, path = ".")}
    facts = {
        hosted_fact_key("charcode", "1.4.0", _SHA): ["myapp"],
        hosted_fact_key("meta", "1.19.0", _OTHER_SHA): [],
        git_fact_key("myapp", _REF, "."): ["charcode"],
    }
    split = split_scope_facts(facts, hosted, git_pkgs)
    asserts.equals(env, ["charcode"], sorted(split.hosted_miss.keys()), "only the bumped package is fetched")
    asserts.equals(env, {}, split.git_miss)
    asserts.true(env, "charcode" not in split.deps, "the bumped package has no hit deps")
    asserts.equals(env, [], split.deps["meta"])
    return unittest.end(env)

def _split_no_facts_test_impl(ctx):
    env = unittest.begin(ctx)
    hosted = {"charcode": _hosted()}
    git_pkgs = {"myapp": _git(path = ".")}
    split = split_scope_facts({}, hosted, git_pkgs)
    asserts.equals(env, ["charcode"], sorted(split.hosted_miss.keys()), "no facts fetch everything hosted")
    asserts.equals(env, ["myapp"], sorted(split.git_miss.keys()), "no facts fetch everything git")
    asserts.equals(env, {}, split.deps)
    return unittest.end(env)

def _split_git_bump_test_impl(ctx):
    env = unittest.begin(ctx)
    git_pkgs = {"myapp": _git(ref = _OTHER_REF, path = ".")}
    facts = {git_fact_key("myapp", _REF, "."): ["charcode"]}
    split = split_scope_facts(facts, {}, git_pkgs)
    asserts.equals(env, ["myapp"], sorted(split.git_miss.keys()), "a ref bump is a miss")
    asserts.equals(env, {}, split.hosted_miss)
    return unittest.end(env)

_DIO_PUBSPEC = """\
name: dio
dependencies:
  dio_web_adapter: ">=1.1.0 <3.0.0"
  meta: ^1.5.0
"""

_ADAPTER_PUBSPEC = """\
name: dio_web_adapter
dependencies:
  dio: ^5.8.0
  meta: ^1.5.0
"""

def _plan_matches_contents_test_impl(ctx):
    env = unittest.begin(ctx)
    contents = {
        "dio": _DIO_PUBSPEC,
        "dio_web_adapter": _ADAPTER_PUBSPEC,
        "meta": "name: meta\n",
    }
    deps = {name: parse_pubspec_deps(contents[name]) for name in contents.keys()}
    from_facts = plan_scope_sccs(
        ["dio", "dio_web_adapter", "meta"],
        {},
        ["pub_deps"],
        "dart_pub",
        contents_from_fact_deps(deps),
    )
    from_contents = plan_scope_sccs(
        ["dio", "dio_web_adapter", "meta"],
        {},
        ["pub_deps"],
        "dart_pub",
        contents,
    )
    asserts.equals(env, from_contents.members, from_facts.members, "facts plan merges the same cycle")
    asserts.equals(env, from_contents.merged, from_facts.merged, "facts plan names the same repositories")
    asserts.equals(
        env,
        {"dio": "dart_pub__scc__dio__dio_web_adapter", "dio_web_adapter": "dart_pub__scc__dio__dio_web_adapter"},
        from_facts.members,
    )
    return unittest.end(env)

def _synthesised_round_trip_test_impl(ctx):
    env = unittest.begin(ctx)
    made = contents_from_fact_deps({"aaa": ["ccc", "bbb"], "empty": []})
    asserts.equals(env, ["bbb", "ccc"], parse_pubspec_deps(made["aaa"]), "recorded deps round-trip sorted")
    asserts.equals(env, [], parse_pubspec_deps(made["empty"]), "an empty dep list stays empty")
    return unittest.end(env)

def _foreign_schema_ignored_test_impl(ctx):
    env = unittest.begin(ctx)
    hosted = {"charcode": _hosted()}
    facts = {
        "pub.scc.v0/hosted/charcode/1.4.0/%s" % _SHA: ["stale"],
        "unrelated": ["x"],
        hosted_fact_key("meta", "9.9.9", _SHA): ["y"],
    }
    split = split_scope_facts(facts, hosted, {})
    asserts.equals(env, ["charcode"], sorted(split.hosted_miss.keys()), "a foreign-schema fact is no hit")
    recorded = {}
    record_scope_facts(recorded, split, {"charcode": "name: charcode\ndependencies:\n  myapp: any\n"})
    asserts.equals(env, ["myapp"], recorded[hosted_fact_key("charcode", "1.4.0", _SHA)], "the planned package is recorded")
    asserts.equals(env, [hosted_fact_key("charcode", "1.4.0", _SHA)], sorted(recorded.keys()), "foreign and stale entries are dropped from the returned facts")
    return unittest.end(env)

def _malformed_fact_test_impl(ctx):
    env = unittest.begin(ctx)
    key = hosted_fact_key("charcode", "1.4.0", _SHA)
    for bad in ["myapp", 42, {"deps": ["myapp"]}, ["myapp", 42], [["myapp"]], None]:
        err = fact_deps_error(key, bad)
        asserts.true(env, err != None, "malformed value %r fails" % (bad,))
        asserts.true(env, key in err, "the error names the key: %s" % err)
    asserts.equals(env, None, fact_deps_error(key, ["myapp", "path"]), "a list of strings is valid")
    asserts.equals(env, None, fact_deps_error(key, []), "an empty list is valid")
    asserts.equals(env, ["myapp", "path"], lookup_fact_deps({key: ["path", "myapp"]}, key), "hits come back sorted")
    asserts.equals(env, None, lookup_fact_deps({}, key), "a missing key is a miss")
    return unittest.end(env)

def _check(package_name = "charcode", root = "/root/pkg", real = "/root/pkg/pubspec.yaml", exists = True, listed = False):
    return struct(
        package_name = package_name,
        root_expected_str = root,
        root_real_str = root,
        pubspec_rel = "pubspec.yaml",
        exists = exists,
        listed = listed,
        real_str = real,
    )

def _scratch_inside_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, scratch_pubspec_error(_check()), "an inside link may be read")
    asserts.equals(env, None, scratch_pubspec_error(_check(real = "/root/pkg", exists = True)), "the root itself is inside")
    return unittest.end(env)

def _scratch_escaping_test_impl(ctx):
    env = unittest.begin(ctx)
    err = scratch_pubspec_error(_check(real = "/etc/passwd"))
    asserts.true(env, err != None, "an escaping link fails")
    asserts.true(env, "charcode" in err, "the diagnostic names the package: %s" % err)
    asserts.true(env, "symlink" in err, "the diagnostic says symlink: %s" % err)
    sibling = scratch_pubspec_error(_check(real = "/root/pkg2/pubspec.yaml"))
    asserts.true(env, sibling != None and "symlink" in sibling, "a sibling prefix escapes: %s" % sibling)
    return unittest.end(env)

def _scratch_dangling_test_impl(ctx):
    env = unittest.begin(ctx)
    err = scratch_pubspec_error(_check(exists = False, listed = True, real = ""))
    asserts.true(env, err != None, "a dangling symlink fails")
    asserts.true(env, "charcode" in err and "symlink" in err, "the diagnostic names the package and says symlink: %s" % err)
    return unittest.end(env)

def _scratch_missing_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, scratch_pubspec_error(_check(exists = False, listed = False, real = "")), "a missing pubspec reads as empty")
    return unittest.end(env)

def _scratch_root_link_test_impl(ctx):
    env = unittest.begin(ctx)
    check = _check()
    check = struct(
        package_name = check.package_name,
        root_expected_str = check.root_expected_str,
        root_real_str = "/elsewhere/pkg",
        pubspec_rel = check.pubspec_rel,
        exists = check.exists,
        listed = check.listed,
        real_str = check.real_str,
    )
    err = scratch_pubspec_error(check)
    asserts.true(env, err != None, "a root that does not resolve to itself fails")
    asserts.true(env, "charcode" in err and "symlink" in err, "the diagnostic names the package and says symlink: %s" % err)
    return unittest.end(env)

_t0_test = unittest.make(_hosted_key_test_impl)
_t1_test = unittest.make(_git_key_test_impl)
_t2_test = unittest.make(_split_full_facts_test_impl)
_t3_test = unittest.make(_split_one_bump_test_impl)
_t4_test = unittest.make(_split_no_facts_test_impl)
_t5_test = unittest.make(_split_git_bump_test_impl)
_t6_test = unittest.make(_plan_matches_contents_test_impl)
_t7_test = unittest.make(_synthesised_round_trip_test_impl)
_t8_test = unittest.make(_foreign_schema_ignored_test_impl)
_t9_test = unittest.make(_malformed_fact_test_impl)
_t10_test = unittest.make(_scratch_inside_test_impl)
_t11_test = unittest.make(_scratch_escaping_test_impl)
_t12_test = unittest.make(_scratch_dangling_test_impl)
_t13_test = unittest.make(_scratch_missing_test_impl)
_t14_test = unittest.make(_scratch_root_link_test_impl)

def pub_scc_facts_test_suite(name):
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
    )
