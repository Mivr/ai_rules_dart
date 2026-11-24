"""Tests for the kernel `unused_inputs_list` wiring (`flutter_kernel_module`).

Every Flutter kernel-module compile — the aspect's library modules (debug and
product) and the test, web, and app entry modules — writes the
`unused_inputs_list` rules_dart's `kernel_module` tool derives, so Bazel skips
the compile when only inputs it did not use changed. The fixture
(`flutter/tests/unused_inputs_fixture`) packs every dependency shape the list
must keep into one closure: `:a` adopts `:b`'s `part of` file, re-exports
`:c`, and folds a constant from `:d`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_action")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _kernel_actions(env):
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.true(
        env,
        len(kernel_actions) > 0,
        "expected DartKernel actions, got %s" % [a.mnemonic for a in actions],
    )
    return kernel_actions

def _entry_unused_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    for action in _kernel_actions(env):
        basenames = [f.basename for f in action.outputs.to_list()]
        lists = [b for b in basenames if b.endswith(".unused_inputs")]
        asserts.equals(
            env,
            1,
            len(lists),
            "each DartKernel action declares one unused-inputs list, got %s" % basenames,
        )
    entries = [
        a
        for a in _kernel_actions(env)
        if any(["flutter_entry.kmod" in f.basename for f in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(entries), "the test compiles one flutter entry module")
    basenames = [f.basename for f in entries[0].outputs.to_list()]
    asserts.true(
        env,
        ctx.attr.target_under_test.label.name + ".flutter_entry.kmod.unused_inputs" in basenames,
        "the entry action declares the unused-inputs list, got %s" % basenames,
    )
    return analysistest.end(env)

_entry_unused_inputs_test = analysistest.make(_entry_unused_inputs_test_impl)

def _fake_file(path):
    short_path = path
    return struct(
        basename = short_path.split("/")[-1],
        is_directory = False,
        is_source = True,
        path = short_path,
        short_path = short_path,
    )

def _record_add_all(added, *a, **kw):
    """Records an `add_all` call; a `before_each` call also leaves a `struct` with its flag and values."""
    added.append(a[0])
    if "before_each" in kw:
        values = a[0].to_list() if type(a[0]) == "depset" else list(a[0])
        added.append(struct(before_each = kw["before_each"], values = values))

def _fake_args(added):
    # Records single-argument adds as strings and `--flag value` adds as
    # pairs, so tests can assert both forwarded flags and multi-root values.
    # `add_all(..., before_each = flag)` also records a `struct(before_each, values)`.
    return struct(
        add = lambda *a, **_kw: added.append(a[0] if len(a) == 1 else a),
        add_all = lambda *a, **kw: _record_add_all(added, *a, **kw),
        set_param_file_format = lambda *a, **_kw: None,
        use_param_file = lambda *a, **_kw: None,
    )

def _compile(added, runs, **kw):
    """Runs `flutter_kernel_module_action` against a fake context, capturing the action."""
    fake_actions = struct(
        declare_file = lambda name, **_kw: _fake_file("bazel-out/bin/fake/" + name),
        symlink = lambda **_kw: None,
        write = lambda **_kw: None,
        args = lambda: _fake_args(added),
        run = lambda **run_kw: runs.append(run_kw),
    )
    fake_ctx = struct(
        label = struct(name = "manual_target", package = "flutter/tests/foo"),
        attr = struct(tags = ["manual"], _kernel_module = None),
        executable = struct(_kernel_module = _fake_file("kernel_module.dill")),
        actions = fake_actions,
    )
    fake_tools = struct(
        dart = _fake_file("dart"),
        dartvm = _fake_file("dartvm"),
        runtime_files = None,
        dartaotruntime = _fake_file("dartaotruntime"),
        module_compiler = _fake_file("module_compiler.aot"),
        platform_dill = _fake_file("platform_strong.dill"),
        libraries_json = _fake_file("libraries.json"),
        version = "3.13.5",
    )
    kwargs = dict(
        koutline = None,
        extra_inputs = None,
        closure_excluded = None,
        droppable = True,
        unused_inputs = False,
    )
    kwargs.update(kw)
    module = struct(
        sources = [struct(
            uri = "package:unused_a/adopt.dart",
            file = _fake_file("flutter/tests/unused_inputs_fixture/a/lib/adopt.dart"),
        )],
        packages = [],
        dep_kmods = depset(),
        output = _fake_file("manual_target.flutter.kmod"),
        koutline = kwargs["koutline"],
        extra_inputs = kwargs["extra_inputs"],
        closure_excluded = kwargs["closure_excluded"],
    )
    options = struct(
        defines = [],
        exclude_non_sources = True,
        droppable = kwargs["droppable"],
        target = "flutter",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = APP_SCHEME,
        extra_frontend_flags = [],
        unused_inputs = kwargs["unused_inputs"],
    )
    flutter_kernel_module_action(ctx = fake_ctx, tools = fake_tools, module = module, options = options)

def _library_unused_inputs_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(
        added,
        runs,
        koutline = _fake_file("manual_target.flutter.koutline"),
        unused_inputs = True,
    )
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] != None,
        "unused_inputs = True passes unused_inputs_list to the action",
    )
    asserts.equals(
        env,
        "manual_target.flutter.kmod.unused_inputs",
        runs[0]["unused_inputs_list"].basename,
        "the list file sits next to the module output",
    )
    flags = [a for a in added if type(a) == "string"] + [a[0] for a in added if type(a) == "tuple"]
    for flag in ["--unused-inputs-list", "--own-source-file", "--input-source"]:
        asserts.true(
            env,
            flag in flags,
            "unused_inputs = True forwards %s to kernel_module" % flag,
        )
    return unittest.end(env)

def _entry_extra_inputs_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(
        added,
        runs,
        droppable = False,
        extra_inputs = depset([_fake_file("flutter/tests/unused_inputs_fixture/b/lib/other.dart")]),
        unused_inputs = True,
    )
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] != None,
        "an entry compile takes unused_inputs_list",
    )
    return unittest.end(env)

def _declared_sources_test_impl(ctx):
    """The compile is told every source the action gives it, and no other.

    The module compiler reads only the files its request declares
    (`--input-source`), so a source the action takes as an input but does not
    declare would be missing for the compile, and the library that needs it
    would silently be left out of the module. That holds for the module's own
    source and for an extra input. The sources are read where they are: no
    staged copy is an input.
    """
    env = unittest.begin(ctx)
    added = []
    runs = []
    extra = _fake_file("flutter/tests/unused_inputs_fixture/b/lib/other.dart")
    _compile(added, runs, extra_inputs = depset([extra]))
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    declared = {a[1].path: True for a in added if type(a) == "tuple" and a[0] == "--input-source"}
    for batch in [a for a in added if type(a) == "struct" and a.before_each == "--input-source"]:
        for f in batch.values:
            declared[f.path] = True
    inputs = [f.path for f in runs[0]["inputs"].to_list()]
    sources = [p for p in inputs if p.endswith(".dart")]
    staged = [p for p in sources if ".stage/" in p]
    asserts.equals(env, [], staged, "no source is staged, got inputs %s" % inputs)
    asserts.equals(
        env,
        sorted(sources),
        sorted(declared.keys()),
        "every source among the action's inputs is declared to the compile, and nothing else is",
    )
    for path in ["flutter/tests/unused_inputs_fixture/a/lib/adopt.dart", extra.path]:
        asserts.true(env, path in declared, "%s is declared" % path)
    return unittest.end(env)

def _default_no_list_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(added, runs)
    asserts.equals(env, 1, len(runs), "registers one DartKernel action by default")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] == None,
        "the default registers the historical action with no list",
    )
    flags = [a for a in added if type(a) == "string"] + [a[0] for a in added if type(a) == "tuple"]
    asserts.true(
        env,
        "--unused-inputs-list" not in flags,
        "the default passes no --unused-inputs-list to kernel_module",
    )
    asserts.true(
        env,
        "--own-source-file" not in flags,
        "the default reports no own sources for the used-input check",
    )
    return unittest.end(env)

def _roots_in_place_test_impl(ctx):
    """A modular kernel compile mounts the roots its declared files sit under, and stages nothing.

    The module compiler serves only the files the request declares
    (`--input-source`), so mounting the exec root exposes no undeclared file;
    a source file's root is the exec root (`.`) and a generated file's its
    output directory, which comes first so a generated file shadows a source
    at the same path.
    """
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(added, runs, unused_inputs = True)
    roots = []
    for batch in [a for a in added if type(a) == "struct" and a.before_each == "--multi-root"]:
        roots.extend(batch.values)
    asserts.equals(env, ["."], roots, "a module of source files mounts the exec root alone")
    generated = _fake_file("bazel-out/k8-fastbuild/bin/flutter/tests/unused_inputs_fixture/b/lib/gen.dart")
    generated = struct(is_directory = False, is_source = False, path = generated.path, short_path = "flutter/tests/unused_inputs_fixture/b/lib/gen.dart")
    added = []
    runs = []
    _compile(added, runs, extra_inputs = depset([generated]))
    roots = []
    for batch in [a for a in added if type(a) == "struct" and a.before_each == "--multi-root"]:
        roots.extend(batch.values)
    asserts.equals(env, ["bazel-out/k8-fastbuild/bin", "."], roots, "a generated file's root comes before the exec root")
    return unittest.end(env)

_library_unused_inputs_test = unittest.make(_library_unused_inputs_test_impl)
_entry_extra_inputs_test = unittest.make(_entry_extra_inputs_test_impl)
_declared_sources_test = unittest.make(_declared_sources_test_impl)
_default_no_list_test = unittest.make(_default_no_list_test_impl)
_roots_in_place_test = unittest.make(_roots_in_place_test_impl)

def unused_inputs_test_suite(name):
    """Defines tests for the kernel `unused_inputs_list` wiring.

    Args:
        name: The test suite name.
    """
    small_unittest_suite(
        name,
        _library_unused_inputs_test,
        _entry_extra_inputs_test,
        _declared_sources_test,
        _default_no_list_test,
        _roots_in_place_test,
    )
    _entry_unused_inputs_test(
        name = name + "_entry",
        target_under_test = "//flutter/tests/unused_inputs_fixture:fixture_test",
    )
