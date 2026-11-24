"""Tests for native-asset propagation through the Dart package graph.

The central claim: a code asset declared on the `dart_library` of the package
that owns it, or produced by its build hook, reaches every
`dart_binary`/`dart_test` depending on that package, directly or
transitively — matching upstream, where depending on a package gets you its
assets with no opt-in. Which asset ids those are is known only when the hooks
have run, so the manifest step checks them (`hook_runner_test.dart`); these
tests check the files that carry them.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_agreement_error", "package_native_assets")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

def _pkg(package_name, lib_root, native_assets = (), version = "", language_version = ""):
    return DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
        version = version,
        language_version = language_version,
        native_assets = native_assets,
    )

# --- merge_package_records: dedup and asset union ---

def _two_hubs_supply_one_package_test_impl(ctx):
    # Regression: two independent pub hubs — rules_flutter's `flutter.pub()`
    # and rules_dart's `pub.from_lock()` — each generate a spoke for `ffi`,
    # giving one package name two `lib_root`s. This is normal, not an error.
    # The same shape arises from a package deliberately split across
    # `dart_library` targets, which `colocate_packages` exists to support.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("ffi", "../rules_flutter++flutter+deps__ffi"),
        _pkg("ffi", "../rules_dart++pub+dart_pub__ffi"),
        _pkg("meta", "../rules_flutter++flutter+deps__meta"),
        _pkg("meta", "../rules_dart++pub+dart_pub__meta"),
    ])
    asserts.equals(env, ["ffi", "meta"], [p.package_name for p in packages])

    # First record wins for source resolution, as it always has.
    asserts.equals(env, "../rules_flutter++flutter+deps__ffi", packages[0].lib_root)
    return unittest.end(env)

def _unions_assets_across_differing_roots_test_impl(ctx):
    # Differing roots must still not lose assets: that silent drop is the one
    # thing the dedup can get wrong, and it surfaces at runtime as an
    # unresolved @Native symbol rather than at build time.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("split", "first/split", ("first/a.assets.json",)),
        _pkg("split", "second/split", ("second/b.hook",)),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, ("first/a.assets.json", "second/b.hook"), package_native_assets(packages[0]))
    return unittest.end(env)

def _collect_unions_same_root_assets_test_impl(ctx):
    # Two dart_library targets splitting one package must not lose the second
    # one's assets to first-wins dedup.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("shared", "pkgs/shared", ("a.assets.json", "liba.so")),
        _pkg("shared", "pkgs/shared", ("a.assets.json", "liba.so", "b.hook")),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, ("a.assets.json", "liba.so", "b.hook"), package_native_assets(packages[0]))
    return unittest.end(env)

def _union_keeps_other_fields_test_impl(ctx):
    # The union branch rebuilds the kept record. Everything it was carrying
    # besides the assets has to survive that rebuild — `language_version`
    # wrong means a package compiles under the wrong Dart semantics, and a
    # lost `hook_error` means the build stops refusing a package whose build
    # hook cannot run.
    env = unittest.begin(ctx)
    kept = DartPackageInfo(
        package_name = "dual",
        lib_root = "first/dual",
        version = "1.2.3",
        language_version = "3.4",
        native_assets = ("a.assets.json",),
        hook_error = "merged into a cycle",
    )
    packages = merge_package_records([
        kept,
        _pkg("dual", "second/dual", ("b.hook",)),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, "first/dual", packages[0].lib_root)
    asserts.equals(env, "1.2.3", packages[0].version)
    asserts.equals(env, "3.4", packages[0].language_version)
    asserts.equals(env, "merged into a cycle", packages[0].hook_error)
    asserts.equals(env, ("a.assets.json", "b.hook"), package_native_assets(packages[0]))
    return unittest.end(env)

def _collect_tolerates_missing_field_test_impl(ctx):
    # DartPackageInfo produced outside rules_dart (rules_flutter builds its
    # own) may omit `native_assets`; that must not crash the collector.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        DartPackageInfo(package_name = "legacy", lib_root = "legacy"),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, (), package_native_assets(packages[0]))
    return unittest.end(env)

# --- package_agreement_error: disagreeing duplicates ---

def _agreement_accepts_agreeing_duplicates_test_impl(ctx):
    # The normal dual-hub case: two hubs, one package, same version. This is
    # the shape `//:wt_live_session_test` has in practice, and it must stay
    # buildable — the duplicate itself is not the defect.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("ffi", "../rules_flutter++flutter+deps__ffi", version = "2.2.0", language_version = "3.7"),
        _pkg("ffi", "../rules_dart++pub+dart_pub__ffi", version = "2.2.0", language_version = "3.7"),
    ])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _agreement_rejects_disagreeing_versions_test_impl(ctx):
    # The measured failure: skewing one lock to ffi 2.1.5 while the other
    # stayed at 2.2.0 built successfully with zero diagnostics, compiling a
    # package that pins 2.2.0 against 2.1.5 sources. Dependency order decided
    # and nothing fired. Both roots and both versions belong in the message —
    # the reader has to know which two hubs to reconcile.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("ffi", "../rules_flutter++flutter+deps__ffi", version = "2.1.5"),
        _pkg("ffi", "../rules_dart++pub+dart_pub__ffi", version = "2.2.0"),
    ])
    asserts.true(env, err != None, "disagreeing versions must be reported")
    asserts.true(env, "2.1.5" in err, "message names the first version")
    asserts.true(env, "2.2.0" in err, "message names the second version")
    asserts.true(env, "ffi" in err, "message names the package")
    asserts.true(
        env,
        "../rules_dart++pub+dart_pub__ffi" in err,
        "message names each record's lib_root",
    )
    return unittest.end(env)

def _agreement_tolerates_one_sided_version_test_impl(ctx):
    # The adoption path. A `DartPackageInfo` from a producer that has not
    # adopted `version` — any rule set outside rules_dart, on its own schedule,
    # and `//dart/tests/no_lv_fixture` in this repo — carries "". Comparing an
    # empty against a known version would fail every dual-hub build
    # immediately, including the agreeing ones, so only two *known* versions
    # can disagree.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("ffi", "../rules_flutter++flutter+deps__ffi"),
        _pkg("ffi", "../rules_dart++pub+dart_pub__ffi", version = "2.2.0"),
    ])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _agreement_rejects_disagreeing_language_versions_test_impl(ctx):
    # Not a proxy for the version check — its own defect. A record states the
    # language version its sources were written against; keeping one and
    # discarding the other silently compiles a package under semantics nobody
    # declared for it.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("split", "first/split", language_version = "3.7"),
        _pkg("split", "second/split", language_version = "3.4"),
    ])
    asserts.true(env, err != None, "disagreeing language versions must be reported")
    asserts.true(env, "3.7" in err, "message names the first language version")
    asserts.true(env, "3.4" in err, "message names the second language version")
    return unittest.end(env)

def _agreement_tolerates_one_sided_language_version_test_impl(ctx):
    # The split-package case `colocate_packages` serves: one `dart_library`
    # sets `language_version`, its sibling omits it. Nothing is in conflict —
    # one record simply knows less than the other.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("split", "first/split", language_version = "3.7"),
        _pkg("split", "second/split"),
    ])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _agreement_ignores_distinct_packages_test_impl(ctx):
    # Different packages disagreeing about anything is not a disagreement.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("a", "first/a", version = "1.0.0", language_version = "3.7"),
        _pkg("b", "first/b", version = "2.0.0", language_version = "3.4"),
    ])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _agreement_tolerates_records_without_the_field_test_impl(ctx):
    # A `DartPackageInfo` from a producer predating `version` omits the field
    # entirely rather than carrying "". Reads must be tolerant, as they are for
    # `native_assets` and `language_version`.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        DartPackageInfo(package_name = "legacy", lib_root = "first/legacy"),
        _pkg("legacy", "second/legacy", version = "1.0.0"),
    ])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _agreement_reports_every_disagreeing_package_test_impl(ctx):
    # The measured cost of stopping at the first: a real lock skew between two
    # sibling repos disagreed on `clock`, `io` and `stack_trace` at once, and
    # reporting only the alphabetically-first turned one reconciliation into
    # three fix-and-re-analyse rounds. `--keep_going` does not help, because
    # every one of the 66 failing targets named the same first package. All of
    # them are already in `stated` when the first is found, so all of them
    # belong in the message.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("clock", "../flutter_hub__clock", version = "1.1.2"),
        _pkg("clock", "../dart_hub__clock", version = "1.1.3"),
        _pkg("io", "../flutter_hub__io", version = "1.0.4"),
        _pkg("io", "../dart_hub__io", version = "1.0.5"),
        _pkg("stack_trace", "../flutter_hub__stack_trace", version = "1.11.1"),
        _pkg("stack_trace", "../dart_hub__stack_trace", version = "1.12.0"),
    ])
    asserts.true(env, err != None, "disagreeing versions must be reported")
    for package_name in ("clock", "io", "stack_trace"):
        asserts.true(env, ('"%s"' % package_name) in err, "message names %s" % package_name)
    for value in ("1.1.2", "1.1.3", "1.0.4", "1.0.5", "1.11.1", "1.12.0"):
        asserts.true(env, value in err, "message names version %s" % value)

    # One remedy for the field, not one per package: three copies of the same
    # paragraph is what makes a multi-package report unreadable.
    asserts.equals(
        env,
        1,
        err.count("rules_dart does not support multiple versions"),
        "the version remedy appears once, not once per package",
    )
    return unittest.end(env)

def _agreement_reports_both_fields_together_test_impl(ctx):
    # A version disagreement must not mask a language-version one. They are
    # separate defects with separate remedies, and a user who fixes the locks
    # only to be shown the next field has paid for a whole re-analysis to learn
    # something the first message already knew.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("clock", "../flutter_hub__clock", version = "1.1.2"),
        _pkg("clock", "../dart_hub__clock", version = "1.1.3"),
        _pkg("split", "first/split", language_version = "3.7"),
        _pkg("split", "second/split", language_version = "3.4"),
    ])
    asserts.true(env, err != None, "both disagreements must be reported")
    asserts.true(env, '"clock"' in err, "message names the version mismatch")
    asserts.true(env, '"split"' in err, "message names the language-version mismatch")
    asserts.true(env, "1.1.2" in err and "1.1.3" in err, "message names both versions")
    asserts.true(env, "3.7" in err and "3.4" in err, "message names both language versions")
    asserts.true(
        env,
        "rules_dart does not support multiple versions" in err,
        "the version remedy is present",
    )
    asserts.true(
        env,
        "Set `language_version` consistently on every" in err,
        "the language-version remedy is present",
    )
    return unittest.end(env)

# --- end-to-end propagation through real rules ---

def _diamond_probe_impl(ctx):
    infos = [dep[DartInfo] for dep in ctx.attr.deps]
    files = depset(transitive = [i.transitive_native_assets for i in infos]).to_list()
    indexes = sorted([f.basename for f in files if f.basename.endswith(".assets.json")])
    if indexes != sorted(ctx.attr.expected_indexes) or len(files) != ctx.attr.expected_file_count:
        fail("%s: expected %d native-asset file(s) in DartInfo, indexes %s; got %s" %
             (ctx.label, ctx.attr.expected_file_count, sorted(ctx.attr.expected_indexes), [f.short_path for f in files]))
    return [DefaultInfo(files = depset(files))]

diamond_probe = rule(
    implementation = _diamond_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "expected_file_count": attr.int(),
        "expected_indexes": attr.string_list(),
    },
    doc = "Asserts which native-asset files a `dart_library` graph propagates, once each.",
)

def _manifest_reads_test_impl(ctx):
    """Asserts the binary's manifest step reads the asset.

    The probe above proves the provider graph carries the asset; this proves
    the terminal rule hands it to the one action that writes the manifest the
    compiler embeds, which is what makes it resolvable at run time.
    """
    env = analysistest.begin(ctx)
    steps = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartNativeAssets"]
    asserts.equals(env, 1, len(steps), "expected exactly one DartNativeAssets action")
    inputs = [f.basename for f in steps[0].inputs.to_list()]
    for name in ctx.attr.expected_files:
        asserts.true(env, name in inputs, "%s not read by the manifest step: %s" % (name, inputs))
    yaml = [f for f in steps[0].outputs.to_list() if f.basename.endswith(".native_assets.yaml")]
    asserts.equals(env, 1, len(yaml), "the step writes the manifest")
    return analysistest.end(env)

manifest_contains_test = analysistest.make(
    _manifest_reads_test_impl,
    attrs = {"expected_files": attr.string_list()},
)

def _spoke_runs_build_hook_test_impl(ctx):
    # A pub package that ships `hook/build.dart` gets a library that runs it:
    # one hook compile, one hook run, and the run's output directory is the
    # package's native asset.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)
    runs = [a for a in actions if a.mnemonic == "DartBuildHook"]
    compiles = [a for a in actions if a.mnemonic == "DartHookCompile"]
    asserts.equals(env, 1, len(runs))
    asserts.equals(env, 1, len(compiles))
    own = [
        p
        for p in target[DartInfo].transitive_packages.to_list()
        if p.package_name == ctx.attr.package_name
    ]
    asserts.equals(env, 1, len(own))
    asserts.equals(env, runs[0].outputs.to_list(), list(package_native_assets(own[0])))
    return analysistest.end(env)

spoke_runs_build_hook_test = analysistest.make(
    _spoke_runs_build_hook_test_impl,
    attrs = {"package_name": attr.string()},
    # The actions of a build hook, which Apple targets refuse: not the host's.
    config_settings = {"//command_line_option:platforms": str(Label("//dart/pub/tests:linux_x64"))},
)

def _ownership_violation_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not namespaced to this package")
    return analysistest.end(env)

ownership_violation_test = analysistest.make(
    _ownership_violation_test_impl,
    expect_failure = True,
)

def _version_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is supplied more than once with different versions")
    return analysistest.end(env)

version_conflict_test = analysistest.make(
    _version_conflict_test_impl,
    expect_failure = True,
)

_t4_test = unittest.make(_collect_unions_same_root_assets_test_impl)
_t5_test = unittest.make(_collect_tolerates_missing_field_test_impl)
_t6_test = unittest.make(_two_hubs_supply_one_package_test_impl)
_t7_test = unittest.make(_unions_assets_across_differing_roots_test_impl)
_t8_test = unittest.make(_union_keeps_other_fields_test_impl)
_t9_test = unittest.make(_agreement_accepts_agreeing_duplicates_test_impl)
_t10_test = unittest.make(_agreement_rejects_disagreeing_versions_test_impl)
_t11_test = unittest.make(_agreement_tolerates_one_sided_version_test_impl)
_t12_test = unittest.make(_agreement_rejects_disagreeing_language_versions_test_impl)
_t13_test = unittest.make(_agreement_tolerates_one_sided_language_version_test_impl)
_t14_test = unittest.make(_agreement_ignores_distinct_packages_test_impl)
_t15_test = unittest.make(_agreement_tolerates_records_without_the_field_test_impl)
_t16_test = unittest.make(_agreement_reports_every_disagreeing_package_test_impl)
_t17_test = unittest.make(_agreement_reports_both_fields_together_test_impl)

def propagation_test_suite(name):
    """Declares the code-asset propagation unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name + "_unit",
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
    spoke_runs_build_hook_test(
        name = name + "_pub_spoke_runs_build_hook_test",
        size = "small",
        package_name = "sqlite3",
        target_under_test = "@ext_pub_deps//:sqlite3",
    )

    # A `dart_library` whose bundled library is a prebuilt file, reached by a
    # `dart_binary` that names no assets itself: the manifest must carry the
    # asset id exactly as it does for a `cc_shared_library`-backed asset.
    manifest_contains_test(
        name = name + "_prebuilt_asset_in_manifest_test",
        size = "small",
        expected_files = ["code_asset.assets.json"],
        target_under_test = "//dart/tests/cc_fixture/prebuilt_prop:app",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_pub_spoke_runs_build_hook_test",
            ":" + name + "_prebuilt_asset_in_manifest_test",
        ],
    )
