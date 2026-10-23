"""Unit tests for root-wins `pub.package()` precedence in `pub_root_pin.bzl`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_root_pin.bzl", "select_all_explicit", "select_pub_package")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

_V191 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"
_V190 = "087ce49c3f0dc39180befefc60fdb4acd8f8620e5682fe2476afd0b3688bb4af"
_ALT = "0000000000000000000000000000000000000000000000000000000000000000"

def _decl(version, sha256, is_root = False, module = "dep_a", deps = []):
    return struct(is_root = is_root, module = module, name = "path", version = version, sha256 = sha256, deps = deps)

def _root_decl(version, sha256, deps = []):
    return _decl(version, sha256, is_root = True, module = "myapp", deps = deps)

def _entry(version, sha256, hub = "pub_deps", lock = "//:pubspec.lock", on_version_conflict = "error"):
    return struct(version = version, sha256 = sha256, hub_name = hub, lock_label = lock, on_version_conflict = on_version_conflict)

def _root_explicit_beats_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _V191), _decl("1.9.0", _V190)], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, "1.9.1", sel.selected.version)
    asserts.equals(env, _V191, sel.selected.sha256)
    asserts.equals(
        env,
        "Pub package \"path\" uses 1.9.1 from the root module's pub.package(), not 1.9.0 declared by module \"dep_a\".",
        sel.note,
    )
    return unittest.end(env)

def _root_lock_beats_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.0", _V190)], [_entry("1.9.1", _V191)])
    asserts.equals(env, None, sel.error)

    # No `pub.package()` applies: the locks resolve the package at the
    # root's version, and the dependency keeps loading against it.
    asserts.equals(env, None, sel.selected)
    asserts.equals(
        env,
        "Pub package \"path\" uses 1.9.1 from //:pubspec.lock, not 1.9.0 declared by module \"dep_a\".",
        sel.note,
    )
    return unittest.end(env)

def _root_older_than_dep_still_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.0", _V190), _decl("1.9.1", _V191)], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, "1.9.0", sel.selected.version)
    asserts.true(env, sel.note != None)
    asserts.true(env, "1.9.0" in sel.note and "1.9.1" in sel.note)
    asserts.true(env, "dep_a" in sel.note)
    return unittest.end(env)

def _note_names_every_overridden_decl_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [
        _decl("1.9.0", _V190, module = "dep_b"),
        _root_decl("1.9.1", _V191),
        _decl("1.8.0", _ALT, module = "dep_a"),
    ], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, "1.9.1", sel.selected.version)
    asserts.equals(
        env,
        "Pub package \"path\" uses 1.9.1 from the root module's pub.package(), not 1.8.0 declared by module \"dep_a\"; 1.9.0 declared by module \"dep_b\".",
        sel.note,
    )
    return unittest.end(env)

def _order_independent_test_impl(ctx):
    env = unittest.begin(ctx)
    first = select_pub_package("path", [_decl("1.9.0", _V190), _root_decl("1.9.1", _V191)], [])
    second = select_pub_package("path", [_root_decl("1.9.1", _V191), _decl("1.9.0", _V190)], [])
    asserts.equals(env, None, first.error)
    asserts.equals(env, None, second.error)
    asserts.equals(env, first.selected.version, second.selected.version)
    asserts.equals(env, first.note, second.note)
    return unittest.end(env)

def _agreeing_dep_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _V191), _decl("1.9.1", _V191)], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, "1.9.1", sel.selected.version)
    asserts.equals(env, None, sel.note)
    return unittest.end(env)

def _agreeing_dep_with_lock_pin_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", _V191)], [_entry("1.9.1", _V191)])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, None, sel.selected)
    asserts.equals(env, None, sel.note)
    return unittest.end(env)

def _root_deps_survive_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _V191, deps = ["meta"]), _decl("1.9.0", _V190, deps = ["other"])], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, ["meta"], sel.selected.deps)
    return unittest.end(env)

def _same_version_other_sha_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _V191), _decl("1.9.1", _ALT)], [])
    asserts.true(env, sel.error != None)
    asserts.true(env, _V191 in sel.error and _ALT in sel.error, "names both values: %s" % sel.error)
    return unittest.end(env)

def _same_version_other_sha_vs_lock_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", _ALT)], [_entry("1.9.1", _V191)])
    asserts.true(env, sel.error != None)
    asserts.true(env, _V191 in sel.error and _ALT in sel.error, "names both values: %s" % sel.error)
    return unittest.end(env)

def _lone_dep_applies_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.0", _V190)], [])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, None, sel.note)
    asserts.equals(env, "1.9.0", sel.selected.version)
    asserts.equals(env, _V190, sel.selected.sha256)
    return unittest.end(env)

def _deps_disagree_without_pin_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", _V191), _decl("1.9.0", _V190, module = "dep_b")], [])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting versions across pub.package() declarations" in sel.error,
        "keeps today's message: %s" % sel.error,
    )
    return unittest.end(env)

def _deps_sha_conflict_without_pin_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", _V191), _decl("1.9.1", _ALT, module = "dep_b")], [])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting sha256 checksums across pub.package() declarations" in sel.error,
        "keeps today's message: %s" % sel.error,
    )
    return unittest.end(env)

def _deps_deps_conflict_without_pin_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", _V191, deps = ["meta"]), _decl("1.9.1", _V191, deps = [], module = "dep_b")], [])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting deps across pub.package() declarations" in sel.error,
        "keeps today's message: %s" % sel.error,
    )
    return unittest.end(env)

def _roots_disagree_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _V191), _decl("1.9.0", _V190, is_root = True, module = "myapp")], [])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting versions across pub.package() declarations" in sel.error,
        "keeps today's message: %s" % sel.error,
    )
    return unittest.end(env)

def _root_explicit_overrides_root_lock_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.0", _V190)], [_entry("1.9.1", _V191)])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, "1.9.0", sel.selected.version)
    asserts.equals(env, None, sel.note)
    return unittest.end(env)

def _root_explicit_lock_sha_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_root_decl("1.9.1", _ALT)], [_entry("1.9.1", _V191)])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting sha256 checksums between pub.package()" in sel.error,
        "keeps today's message: %s" % sel.error,
    )
    asserts.true(env, _ALT in sel.error and _V191 in sel.error)
    return unittest.end(env)

def _root_locks_disagree_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [], [
        _entry("1.9.1", _V191, hub = "a_deps", lock = "//:a.lock"),
        _entry("1.9.0", _V190, hub = "b_deps", lock = "//:b.lock"),
    ])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting versions across lock files" in sel.error,
        "today's cross-lock rule settles the root pin first: %s" % sel.error,
    )
    return unittest.end(env)

def _root_locks_sha_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [], [
        _entry("1.9.1", _V191, hub = "a_deps", lock = "//:a.lock"),
        _entry("1.9.1", _ALT, hub = "b_deps", lock = "//:b.lock"),
    ])
    asserts.true(env, sel.error != None)
    asserts.true(
        env,
        "conflicting sha256 checksums across lock files" in sel.error,
        "today's cross-lock rule settles the root pin first: %s" % sel.error,
    )
    return unittest.end(env)

def _root_locks_upgrade_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [], [
        _entry("1.9.1", _V191, hub = "a_deps", lock = "//:a.lock"),
        _entry("1.9.0", _V190, hub = "b_deps", lock = "//:b.lock", on_version_conflict = "upgrade"),
    ])
    asserts.equals(env, None, sel.error)
    asserts.equals(env, None, sel.selected)
    asserts.equals(env, None, sel.note)
    return unittest.end(env)

def _bad_sha_reports_sha_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_pub_package("path", [_decl("1.9.1", "   ")], [])
    asserts.equals(env, "sha", sel.error_shape)
    asserts.true(env, sel.error != None)
    return unittest.end(env)

def _all_explicit_wires_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    explicit, notes, error, _ = select_all_explicit(
        [
            struct(name = "path", version = "1.9.1", sha256 = _V191, deps = [], is_root = True, module = "myapp"),
            struct(name = "path", version = "1.9.0", sha256 = _V190, deps = [], is_root = False, module = "dep_a"),
            struct(name = "meta", version = "1.11.0", sha256 = _ALT, deps = [], is_root = False, module = "dep_a"),
        ],
        [],
    )
    asserts.equals(env, None, error)
    asserts.equals(env, "1.9.1", explicit["path"].version)
    asserts.equals(env, "1.11.0", explicit["meta"].version)
    asserts.equals(env, 1, len(notes))
    asserts.true(env, "path" in notes[0])
    return unittest.end(env)

def _all_explicit_lock_pin_leaves_locks_test_impl(ctx):
    env = unittest.begin(ctx)
    explicit, notes, error, _ = select_all_explicit(
        [struct(name = "path", version = "1.9.0", sha256 = _V190, deps = [], is_root = False, module = "dep_a")],
        [struct(
            name = "pub_deps",
            lock = "//:pubspec.lock",
            packages = {"path": {
                "source": "hosted",
                "version": "1.9.1",
                "description": {"sha256": _V191, "url": "https://pub.dev"},
            }},
            on_version_conflict = "error",
            isolated = False,
            is_root = True,
            module = "myapp",
        )],
    )
    asserts.equals(env, None, error)
    asserts.equals(env, {}, explicit)
    asserts.equals(env, 1, len(notes))
    return unittest.end(env)

_t0_test = unittest.make(_root_explicit_beats_dep_test_impl)
_t1_test = unittest.make(_root_lock_beats_dep_test_impl)
_t2_test = unittest.make(_root_older_than_dep_still_wins_test_impl)
_t3_test = unittest.make(_note_names_every_overridden_decl_test_impl)
_t4_test = unittest.make(_order_independent_test_impl)
_t5_test = unittest.make(_agreeing_dep_is_silent_test_impl)
_t6_test = unittest.make(_agreeing_dep_with_lock_pin_is_silent_test_impl)
_t7_test = unittest.make(_root_deps_survive_test_impl)
_t8_test = unittest.make(_same_version_other_sha_fails_test_impl)
_t9_test = unittest.make(_same_version_other_sha_vs_lock_fails_test_impl)
_t10_test = unittest.make(_lone_dep_applies_test_impl)
_t11_test = unittest.make(_deps_disagree_without_pin_test_impl)
_t12_test = unittest.make(_deps_sha_conflict_without_pin_test_impl)
_t13_test = unittest.make(_deps_deps_conflict_without_pin_test_impl)
_t14_test = unittest.make(_roots_disagree_test_impl)
_t15_test = unittest.make(_root_explicit_overrides_root_lock_test_impl)
_t16_test = unittest.make(_root_explicit_lock_sha_conflict_test_impl)
_t17_test = unittest.make(_root_locks_disagree_test_impl)
_t18_test = unittest.make(_root_locks_sha_conflict_test_impl)
_t19_test = unittest.make(_root_locks_upgrade_test_impl)
_t20_test = unittest.make(_bad_sha_reports_sha_shape_test_impl)
_t21_test = unittest.make(_all_explicit_wires_pins_test_impl)
_t22_test = unittest.make(_all_explicit_lock_pin_leaves_locks_test_impl)

def pub_root_pin_test_suite(name):
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
    )
