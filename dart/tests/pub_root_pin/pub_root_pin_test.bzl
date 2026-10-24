"""Unit tests for root-wins `pub.package()` precedence in `pub_root_pin.bzl`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:extensions.bzl", "resolve_pub_packages")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_root_pin.bzl", "select_all_explicit", "select_pub_package")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

_V191 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"
_V190 = "087ce49c3f0dc39180befefc60fdb4acd8f8620e5682fe2476afd0b3688bb4af"
_ALT = "0000000000000000000000000000000000000000000000000000000000000000"
_REF = "1111111111111111111111111111111111111111"

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
    asserts.equals(env, None, sel.alias)
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

    # The dependency's `P` repository is still generated, as an alias
    # resolving to the root's version.
    asserts.true(env, sel.alias != None)
    asserts.equals(env, "1.9.1", sel.alias.version)
    asserts.equals(env, _V191, sel.alias.sha256)
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

    # The agreeing declaration still gets its `P` repository, resolving to
    # the root's version.
    asserts.true(env, sel.alias != None)
    asserts.equals(env, "1.9.1", sel.alias.version)
    asserts.equals(env, _V191, sel.alias.sha256)
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
    asserts.equals(env, None, sel.alias)
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
    asserts.equals(env, None, sel.alias)
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
    explicit, aliases, notes, error, _ = select_all_explicit(
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
    asserts.equals(env, {}, aliases)
    asserts.equals(env, 1, len(notes))
    asserts.true(env, "path" in notes[0])
    return unittest.end(env)

def _all_explicit_lock_pin_leaves_locks_test_impl(ctx):
    env = unittest.begin(ctx)
    explicit, aliases, notes, error, _ = select_all_explicit(
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

    # The locks resolve the package, and the dependency's `P` repository
    # is generated as an alias at the root's version.
    asserts.true(env, "path" in aliases)
    asserts.equals(env, "1.9.1", aliases["path"].version)
    asserts.equals(env, _V191, aliases["path"].sha256)
    return unittest.end(env)

def _mod_pkg(version, sha256, module = "depmod", is_root = False, deps = []):
    return struct(name = "path", version = version, sha256 = sha256, deps = deps, is_root = is_root, module = module)

def _hosted_pkg(version, sha256):
    return {"source": "hosted", "version": version, "description": {"sha256": sha256, "url": "https://pub.dev"}}

def _git_pkg(version, ref):
    return {"source": "git", "version": version, "description": {"url": "file:///srv/gp.git", "resolved-ref": ref, "path": "."}}

def _git_pkg_at(version, ref, path):
    return {"source": "git", "version": version, "description": {"url": "file:///srv/gp.git", "resolved-ref": ref, "path": path}}

def _mod_lock(hub, pkgs, module = "root", is_root = True, on_version_conflict = "error", isolated = False):
    return struct(name = hub, lock = "//" + module + ":pubspec.lock", packages = pkgs, on_version_conflict = on_version_conflict, isolated = isolated, is_root = is_root, module = module)

def _check_git_pinned(env, r, version, ref, note):
    asserts.equals(env, None, r.error)
    asserts.equals(env, {}, r.explicit)
    asserts.true(env, "path" in r.aliases)
    asserts.equals(env, version, r.aliases["path"].version)
    asserts.equals(env, ref, r.aliases["path"].resolved_ref)
    asserts.equals(env, version, r.resolved_git["path"].version)
    asserts.equals(env, ref, r.resolved_git["path"].resolved_ref)
    asserts.equals(env, [note], r.notes)

def _root_git_pin_drops_dep_decl_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _V190)],
        [_mod_lock("pub_deps", {"path": _git_pkg("1.4.0", _REF)})],
    )
    _check_git_pinned(
        env,
        r,
        "1.4.0",
        _REF,
        "Pub package \"path\" uses 1.4.0 from git %s in //root:pubspec.lock, not 1.9.0 declared by module \"depmod\"." % _REF,
    )
    return unittest.end(env)

def _root_git_pin_drops_two_dep_decls_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _V190), _mod_pkg("1.8.0", _ALT, module = "depmod2")],
        [_mod_lock("pub_deps", {"path": _git_pkg("1.4.0", _REF)})],
    )
    _check_git_pinned(
        env,
        r,
        "1.4.0",
        _REF,
        "Pub package \"path\" uses 1.4.0 from git %s in //root:pubspec.lock, not 1.9.0 declared by module \"depmod\"; 1.8.0 declared by module \"depmod2\"." % _REF,
    )
    return unittest.end(env)

def _root_git_pin_beats_same_version_decl_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.4.0", _V190)],
        [_mod_lock("pub_deps", {"path": _git_pkg("1.4.0", _REF)})],
    )
    _check_git_pinned(
        env,
        r,
        "1.4.0",
        _REF,
        "Pub package \"path\" uses 1.4.0 from git %s in //root:pubspec.lock, not 1.4.0 declared by module \"depmod\"." % _REF,
    )
    return unittest.end(env)

def _isolated_root_git_entry_does_not_pin_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _V190)],
        [_mod_lock("tool_deps", {"path": _git_pkg("1.4.0", _REF)}, isolated = True)],
    )
    asserts.equals(env, None, r.error)
    asserts.equals(env, "1.9.0", r.explicit["path"].version)
    asserts.equals(env, {}, r.aliases)
    asserts.equals(env, [], r.notes)
    asserts.equals(env, "1.4.0", r.isolated_git_packages["tool_deps"]["path"].version)
    return unittest.end(env)

def _root_decl_still_beats_root_git_lock_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _V190, module = "myapp", is_root = True)],
        [_mod_lock("pub_deps", {"path": _git_pkg("1.4.0", _REF)})],
    )
    asserts.equals(env, None, r.error)
    asserts.equals(env, "1.9.0", r.explicit["path"].version)
    asserts.equals(env, {}, r.aliases)
    asserts.equals(env, [], r.notes)
    return unittest.end(env)

def _upgrade_note_names_resolved_version_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("2.0.0", _ALT)],
        [
            _mod_lock("pub_deps", {"path": _hosted_pkg("1.9.0", _V190)}, on_version_conflict = "upgrade"),
            _mod_lock("dep_deps", {"path": _hosted_pkg("1.9.1", _V191)}, module = "depmod2", is_root = False),
        ],
    )
    asserts.equals(env, None, r.error)
    asserts.equals(env, {}, r.explicit)
    asserts.equals(env, "1.9.1", r.resolved["path"].version)
    asserts.equals(env, _V191, r.resolved["path"].sha256)
    asserts.equals(env, "1.9.1", r.aliases["path"].version)
    asserts.equals(env, _V191, r.aliases["path"].sha256)
    asserts.equals(
        env,
        ["Pub package \"path\" uses 1.9.1 from //depmod2:pubspec.lock, not 2.0.0 declared by module \"depmod\"."],
        r.notes,
    )
    return unittest.end(env)

def _root_pin_hides_no_lock_sha_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _ALT)],
        [
            _mod_lock("pub_deps", {"path": _hosted_pkg("1.9.1", _V191)}),
            _mod_lock("dep_deps", {"path": _hosted_pkg("1.9.0", _V190)}, module = "depmod2", is_root = False),
        ],
    )
    asserts.true(env, r.error != None)
    asserts.true(env, "conflicting sha256 checksums between pub.package()" in r.error, "keeps lock wording: %s" % r.error)
    asserts.true(env, _ALT in r.error and _V190 in r.error, "names both values: %s" % r.error)
    asserts.true(env, "//depmod2:pubspec.lock" in r.error, "names the lock: %s" % r.error)
    return unittest.end(env)

def _root_pin_hides_no_decl_sha_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [_mod_pkg("1.9.0", _V190), _mod_pkg("1.9.0", _ALT, module = "depmod2")],
        [_mod_lock("pub_deps", {"path": _hosted_pkg("1.9.1", _V191)})],
    )
    asserts.true(env, r.error != None)
    asserts.true(env, "conflicting sha256 checksums across pub.package() declarations" in r.error, "keeps decl wording: %s" % r.error)
    asserts.true(env, _V190 in r.error and _ALT in r.error, "names both values: %s" % r.error)
    return unittest.end(env)

def _git_path_conflict_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [],
        [
            _mod_lock("pub_deps", {"path": _git_pkg_at("1.4.0", _REF, "a")}),
            _mod_lock("dep_deps", {"path": _git_pkg_at("1.4.0", _REF, "b")}, module = "depmod2", is_root = False),
        ],
    )
    asserts.true(env, r.error != None)
    asserts.true(env, "conflicting git paths" in r.error, "names the conflict: %s" % r.error)
    asserts.true(env, "\"path\"" in r.error and "1.4.0" in r.error, "names the package: %s" % r.error)
    asserts.true(env, "a" in r.error and "b" in r.error, "names both paths: %s" % r.error)
    asserts.true(env, "pub_deps" in r.error and "dep_deps" in r.error, "names both hubs: %s" % r.error)
    asserts.true(env, "//root:pubspec.lock" in r.error and "//depmod2:pubspec.lock" in r.error, "names both locks: %s" % r.error)
    return unittest.end(env)

def _git_path_conflict_order_independent_test_impl(ctx):
    env = unittest.begin(ctx)
    first = resolve_pub_packages(
        [],
        [
            _mod_lock("pub_deps", {"path": _git_pkg_at("1.4.0", _REF, "a")}),
            _mod_lock("dep_deps", {"path": _git_pkg_at("1.4.0", _REF, "b")}, module = "depmod2", is_root = False),
        ],
    )
    second = resolve_pub_packages(
        [],
        [
            _mod_lock("dep_deps", {"path": _git_pkg_at("1.4.0", _REF, "b")}, module = "depmod2", is_root = False),
            _mod_lock("pub_deps", {"path": _git_pkg_at("1.4.0", _REF, "a")}),
        ],
    )
    for r in [first, second]:
        asserts.true(env, r.error != None)
        asserts.true(env, "conflicting git paths" in r.error, "fails in both lock orders: %s" % r.error)
        asserts.true(env, "//root:pubspec.lock" in r.error and "//depmod2:pubspec.lock" in r.error, "names both locks: %s" % r.error)
    return unittest.end(env)

def _agreeing_git_path_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    r = resolve_pub_packages(
        [],
        [
            _mod_lock("pub_deps", {"path": _git_pkg_at("1.4.0", _REF, "a")}),
            _mod_lock("dep_deps", {"path": _git_pkg_at("1.4.0", _REF, "a")}, module = "depmod2", is_root = False),
        ],
    )
    asserts.equals(env, None, r.error)
    asserts.equals(env, "1.4.0", r.resolved_git["path"].version)
    asserts.equals(env, _REF, r.resolved_git["path"].resolved_ref)
    asserts.equals(env, "a", r.resolved_git["path"].path)
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
_t23_test = unittest.make(_root_git_pin_drops_dep_decl_test_impl)
_t24_test = unittest.make(_root_git_pin_drops_two_dep_decls_test_impl)
_t25_test = unittest.make(_root_git_pin_beats_same_version_decl_test_impl)
_t26_test = unittest.make(_isolated_root_git_entry_does_not_pin_test_impl)
_t27_test = unittest.make(_root_decl_still_beats_root_git_lock_test_impl)
_t28_test = unittest.make(_upgrade_note_names_resolved_version_test_impl)
_t29_test = unittest.make(_root_pin_hides_no_lock_sha_conflict_test_impl)
_t30_test = unittest.make(_root_pin_hides_no_decl_sha_conflict_test_impl)
_t31_test = unittest.make(_git_path_conflict_fails_test_impl)
_t32_test = unittest.make(_git_path_conflict_order_independent_test_impl)
_t33_test = unittest.make(_agreeing_git_path_is_silent_test_impl)

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
        _t23_test,
        _t24_test,
        _t25_test,
        _t26_test,
        _t27_test,
        _t28_test,
        _t29_test,
        _t30_test,
        _t31_test,
        _t32_test,
        _t33_test,
    )
