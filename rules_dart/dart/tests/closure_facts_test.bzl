"""Unit tests for the closure facts `DartInfo` carries (`closure_facts.bzl`).

The facts let analysis skip a walk of the closure, never change what the walk
answers. So the tests come in two kinds: what the merged facts say about a
closure built from fake records, and, for each consumer that has a fact-based
path, that it gives the walk's answer on the same closure. A fake `DartInfo`
here is a struct carrying `transitive_packages` (and `transitive_resources`)
for the walk and `closure_facts` for the facts; the two consumers read nothing
else.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/private:closure_facts.bzl",
    "clean_closure",
    "closure_facts",
    "lib_roots_of",
    "name_key",
    "owner_fields",
    "owner_index",
    "owners_unique",
    "roots_containing",
)
load("//dart/private:dart_analyzer_summary.bzl", "own_lib_sources", "unbacked_embedder_in_closure")

visibility(["//dart/..."])

def _rec(name, root, language_version = "3.11", code_assets = (), hook = ""):
    """A fake `DartPackageInfo` record."""
    return struct(
        package_name = name,
        lib_root = root,
        version = "",
        language_version = language_version,
        code_assets = code_assets,
        has_unreplaced_hook = hook,
        link_hook = None,
    )

def _file(short_path):
    """A fake source or resource `File`."""
    return struct(short_path = short_path, extension = short_path.rpartition(".")[2], is_directory = False)

def _lib(label, records, deps = [], resources = []):
    """A fake `DartInfo` owning `records`, merged over `deps` as `dart_info()` merges."""
    return struct(
        package_name = records[0].package_name if len(records) == 1 else "",
        lib_root = records[0].lib_root if len(records) == 1 else "",
        transitive_packages = depset(records, transitive = [d.transitive_packages for d in deps]),
        transitive_resources = depset(resources, transitive = [d.transitive_resources for d in deps]),
        closure_facts = closure_facts(
            label if records else None,
            records,
            resources,
            deps,
            [d.label for d in deps],
        ),
        label = label,
    )

def _exe(deps):
    """A fake package-less `DartInfo` over `deps`, as `dart_info_no_package()` builds."""
    return struct(
        package_name = "",
        lib_root = "",
        transitive_packages = depset(transitive = [d.transitive_packages for d in deps]),
        transitive_resources = depset(transitive = [d.transitive_resources for d in deps]),
        closure_facts = closure_facts(None, [], [], deps, [d.label for d in deps]),
        label = "//:exe",
    )

def _walk_only(info):
    """The same fake without facts, so consumers take the walk."""
    return struct(
        package_name = info.package_name,
        lib_root = info.lib_root,
        transitive_packages = info.transitive_packages,
        transitive_resources = info.transitive_resources,
    )

def _diamond():
    """A diamond: `top` over `left` and `right`, both over `base`."""
    base = _lib("//base", [_rec("base", "base")])
    left = _lib("//left", [_rec("left", "left")], [base])
    right = _lib("//right", [_rec("right", "right")], [base])
    return _lib("//top", [_rec("top", "top")], [left, right])

def _merge_test_impl(ctx):
    """Unions and flags merge across dependencies; a dependency without facts gives none."""
    env = unittest.begin(ctx)
    sky = _lib("//sky", [_rec("sky_engine", "third_party/sky")], resources = [_file("third_party/sky/lib/_embedder.yaml")])
    root_a = _lib("//:a", [_rec("a", "")])
    root_b = _lib("//:b", [_rec("b", "")])
    hooked = _lib("//h", [_rec("h", "h", hook = "h/hook/build.dart")])
    facts = _exe([sky, root_a, root_b, hooked]).closure_facts
    asserts.equals(env, ("a", "b"), facts.root_names)
    asserts.equals(env, ("third_party/sky/lib/_embedder.yaml",), facts.embedders)
    asserts.equals(env, ("third_party/sky/lib/_embedder.yaml",), facts.sky_engines)
    asserts.true(env, facts.unreplaced_hooks)
    asserts.false(env, facts.code_assets)
    asserts.equals(env, ("//sky", "//:a", "//:b", "//h"), facts.merged)

    bare = struct(transitive_packages = depset(), transitive_resources = depset(), label = "//bare")
    asserts.equals(env, None, _exe([sky, bare]).closure_facts, "a dependency without facts leaves none")
    return unittest.end(env)

_merge_test = unittest.make(_merge_test_impl)

def _clean_test_impl(ctx):
    """A closure is clean only when no name or root repeats, nothing nests, and nothing has assets."""
    env = unittest.begin(ctx)
    top = _diamond()
    asserts.true(env, owners_unique(top.closure_facts), "a diamond reaches each owner twice but owns each key once")
    clean = clean_closure(top.closure_facts)
    asserts.true(env, clean != None)
    asserts.true(env, name_key("base") in clean.index)
    asserts.equals(env, "//base", owner_fields(clean.index[name_key("base")]).label)

    base = _lib("//base", [_rec("base", "base")])
    split = _lib("//base:top", [_rec("base", "base")], [_lib("//mid", [_rec("mid", "mid")], [base])])
    asserts.false(env, owners_unique(split.closure_facts), "two targets owning one package")
    asserts.equals(env, None, clean_closure(split.closure_facts))

    hubs = _exe([_lib("@a//:ffi", [_rec("ffi", "../a")]), _lib("@b//:ffi", [_rec("ffi", "../b")])])
    asserts.equals(env, None, clean_closure(hubs.closure_facts), "one name at two roots")

    shared_root = _exe([_lib("//p:x", [_rec("x", "p")]), _lib("//p:y", [_rec("y", "p")])])
    asserts.equals(env, None, clean_closure(shared_root.closure_facts), "two names at one root")

    nested = _exe([_lib("//a", [_rec("a", "a")]), _lib("//a/lib/b", [_rec("b", "a/lib/b")])])
    asserts.true(env, owners_unique(nested.closure_facts))
    asserts.equals(env, None, clean_closure(nested.closure_facts), "a root inside another package's lib/")

    two_roots = _exe([_lib("//:a", [_rec("a", "")]), _lib("@x//:b", [_rec("b", "")])])
    asserts.equals(env, None, clean_closure(two_roots.closure_facts), "two root packages")

    assets = _exe([_lib("//n", [_rec("n", "n", code_assets = (struct(asset_id = "package:n/x"),))])])
    asserts.equals(env, None, clean_closure(assets.closure_facts), "code assets are merged by the walk")

    versions = _exe([
        _lib("//v", [_rec("v", "v", language_version = "3.10")]),
        _lib("//v", [_rec("v", "v", language_version = "3.11")]),
    ])
    asserts.equals(env, None, clean_closure(versions.closure_facts), "one label in two configurations stating two versions")
    return unittest.end(env)

_clean_test = unittest.make(_clean_test_impl)

def _paths_test_impl(ctx):
    """`lib_roots_of` and `roots_containing` list candidates innermost first."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["a/lib/b", "a"], lib_roots_of("a/lib/b/lib/x.dart"))
    asserts.equals(env, [""], lib_roots_of("lib/x.dart"))
    asserts.equals(env, [], lib_roots_of("test/x_test.dart"))
    asserts.equals(env, [], lib_roots_of("a/lib"))
    asserts.equals(env, ["a/b", "a", ""], roots_containing("a/b/c.dart"))
    asserts.equals(env, [""], roots_containing("c.dart"))
    return unittest.end(env)

_paths_test = unittest.make(_paths_test_impl)

def _embedder_parity_test_impl(ctx):
    """The fact-based embedder check gives the walk's answer."""
    env = unittest.begin(ctx)
    summary = struct(path = "embedder_sdk.sum")
    sky = _lib("//sky", [_rec("sky_engine", "sky")], resources = [_file("sky/lib/_embedder.yaml")])
    other = _lib("//o", [_rec("o", "o")], resources = [_file("o/lib/_embedder.yaml")])
    plain = _lib("//p", [_rec("p", "p")], resources = [_file("p/lib/data.json")])
    for name, info in [
        ("none", _exe([plain])),
        ("backed", _exe([sky, plain])),
        ("unbacked", _exe([sky, other])),
        ("sky without yaml", _exe([_lib("//s2", [_rec("sky_engine", "s2")])])),
    ]:
        for embedder_summary in [summary, None]:
            asserts.equals(
                env,
                unbacked_embedder_in_closure(_walk_only(info), embedder_summary),
                unbacked_embedder_in_closure(info, embedder_summary),
                "%s, summary %s" % (name, embedder_summary != None),
            )
    return unittest.end(env)

_embedder_parity_test = unittest.make(_embedder_parity_test_impl)

def _own_lib_parity_test_impl(ctx):
    """`own_lib_sources` of a package-less target gives the walk's answer from the facts."""
    env = unittest.begin(ctx)
    exe = _exe([_diamond(), _lib("@ext//:e", [_rec("e", "../ext")])])
    files = [
        _file("left/lib/x.dart"),
        _file("left/test/x_test.dart"),
        _file("lib/root.dart"),
        _file("../ext/lib/e.dart"),
        _file("base/lib/data.json"),
    ]
    asserts.equals(env, own_lib_sources(_walk_only(exe), files), own_lib_sources(exe, files))
    asserts.equals(env, [files[0]], own_lib_sources(exe, files))
    return unittest.end(env)

_own_lib_parity_test = unittest.make(_own_lib_parity_test_impl)

def _index_test_impl(ctx):
    """`owner_index` keys every name and root, and says when one repeats."""
    env = unittest.begin(ctx)
    owners = owner_index(_diamond().closure_facts)
    asserts.true(env, owners.unique)
    asserts.equals(env, 8, len(owners.index), "four packages, each with a name and a root")
    fields = owner_fields(owners.index["root:left"])
    asserts.equals(env, ["//left", "left", "left", "3.11"], [fields.label, fields.package_name, fields.lib_root, fields.language_version])
    return unittest.end(env)

_index_test = unittest.make(_index_test_impl)

def closure_facts_test_suite(name):
    """Declares the closure facts unit tests and their `test_suite`.

    Args:
      name: The name of the `test_suite`.
    """
    unittest.suite(
        name,
        _merge_test,
        _clean_test,
        _paths_test,
        _embedder_parity_test,
        _own_lib_parity_test,
        _index_test,
    )
