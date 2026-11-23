"""Small facts about a `DartInfo` closure, carried on the provider.

A consumer that has to know something about the whole closure of a target (is
there a Flutter embedder, do two records name one package, does a package root
sit inside another package's `lib/`) would otherwise flatten
`transitive_packages` and walk it in Starlark, once per target, which makes
analysis quadratic in the size of the graph. These facts are computed once,
where `DartInfo` is built, from the target's own records and its direct
dependencies' facts, so building them costs time in the direct edge only.

Two kinds of fact live here:

  * **Unions and flags.** Whether any record has code assets or an unreplaced
    build hook, which root packages there are, which `lib/_embedder.yaml`
    files the closure ships. A union of the dependencies' values is exactly
    the closure's value, so these are exact.
  * **Owners.** A depset with one entry per package name and one per package
    root, each naming the target that owns the record and the record's own
    facts (`(key, owner)`, both strings; see `owner_fields`), and beside it
    the depset of the keys alone. Whether a name or a root has more than one
    owner is not a property that composes: two dependencies can each be
    clean and still disagree with each other anywhere below. So the owners
    travel as depsets, and a consumer that needs the answer expands them, in
    Java (`owners_unique`, `owner_index`): no Starlark loop runs over the
    closure.

The facts are optional for every reader. A `DartInfo` built by a producer that
predates them, or by hand, carries none, and a target any of whose
dependencies carries none gets none either. A reader then takes the precise
path it always took, so the facts only ever decide when that path can be
skipped, never what it answers.
"""

visibility(["//dart/..."])

# Flutter's embedder package and the file that makes it one. Kept beside
# `embedder_in_closure` in `dart_analyzer_summary.bzl`, which reads the same.
EMBEDDER_PACKAGE = "sky_engine"
EMBEDDER_FILE = "_embedder.yaml"

_NAME = "name:"
_ROOT = "root:"

def is_embedder_yaml(short_path):
    """Whether a file is a package's `lib/_embedder.yaml`.

    Args:
      short_path: A `File.short_path`.

    Returns:
      A bool.
    """
    return short_path == "lib/" + EMBEDDER_FILE or short_path.endswith("/lib/" + EMBEDDER_FILE)

def sky_engine_yaml(lib_root):
    """The path a `sky_engine` record's `lib/_embedder.yaml` has.

    Args:
      lib_root: The record's `lib_root`.

    Returns:
      The `short_path` the embedder file has when the package ships one.
    """
    return ((lib_root + "/lib/") if lib_root else "lib/") + EMBEDDER_FILE

def _nests(lib_root):
    """Whether a package root can sit inside another package's `lib/`.

    A package whose root lies under `<other>/lib/` (or under `lib/` of the
    root package) has a path component named `lib`. A root without one cannot
    be nested so, which is what lets a reader map a file to the one package
    whose `lib/` holds it. An external repository named `lib` is reported
    too, which only sends a reader to its precise path.
    """
    return "lib" in lib_root.split("/")

def name_key(package_name):
    """The `owners` key of a package name."""
    return _NAME + package_name

def root_key(lib_root):
    """The `owners` key of a package root (`lib_root`)."""
    return _ROOT + lib_root

def _owner(label, record):
    """The owner string of one record: its owner's label and its own facts.

    Two records of one name from one label (one target in two
    configurations) differ in it exactly when they state different facts,
    which is what lets the owners stand in for the records. Code assets are
    left out: a closure with any is never treated as clean.
    """
    link_hook = getattr(record, "link_hook", None)
    return "\t".join([
        label,
        record.package_name,
        record.lib_root,
        getattr(record, "version", "") or "",
        getattr(record, "language_version", "") or "",
        getattr(record, "has_unreplaced_hook", "") or "",
        link_hook.path if link_hook != None else "",
    ])

def owner_fields(owner):
    """Splits an owner string back into its fields.

    Args:
      owner: A value of the owner index.

    Returns:
      `struct(label, package_name, lib_root, version, language_version)`.
    """
    parts = owner.split("\t")
    return struct(
        label = parts[0],
        package_name = parts[1],
        lib_root = parts[2],
        version = parts[3],
        language_version = parts[4],
    )

def closure_facts(label, packages, resources, dep_infos, dep_labels):
    """Merges a target's own facts with its dependencies' facts.

    Args:
      label: The target's label, or None when it owns no package record.
      packages: The target's own `DartPackageInfo` records.
      resources: The target's own non-Dart `lib/` files.
      dep_infos: The `DartInfo` of each dependency merged in.
      dep_labels: The label of each of those dependencies, as strings.

    Returns:
      The facts struct, or None when a dependency carries no facts.
    """
    dep_facts = []
    for info in dep_infos:
        facts = facts_of(info)
        if facts == None:
            return None
        dep_facts.append(facts)

    label_str = str(label) if label != None else ""
    entries = []
    keys = []
    root_names = {}
    embedders = {}
    sky_engines = {}
    nested = False
    code_assets = False
    unreplaced_hooks = False
    for record in packages:
        owner = _owner(label_str, record)
        entries.append((name_key(record.package_name), owner))
        entries.append((root_key(record.lib_root), owner))
        keys.append(name_key(record.package_name))
        keys.append(root_key(record.lib_root))
        if not record.lib_root:
            root_names[record.package_name] = True
        if record.package_name == EMBEDDER_PACKAGE:
            sky_engines[sky_engine_yaml(record.lib_root)] = True
        nested = nested or _nests(record.lib_root)
        code_assets = code_assets or bool(getattr(record, "code_assets", ()))
        unreplaced_hooks = unreplaced_hooks or bool(getattr(record, "has_unreplaced_hook", ""))
    for f in resources:
        if is_embedder_yaml(f.short_path):
            embedders[f.short_path] = True

    for facts in dep_facts:
        for name in facts.root_names:
            root_names[name] = True
        for path in facts.embedders:
            embedders[path] = True
        for path in facts.sky_engines:
            sky_engines[path] = True
        nested = nested or facts.nested_roots
        code_assets = code_assets or facts.code_assets
        unreplaced_hooks = unreplaced_hooks or facts.unreplaced_hooks

    return struct(
        owners = depset(entries, transitive = [f.owners for f in dep_facts]),
        owner_keys = depset(keys, transitive = [f.owner_keys for f in dep_facts]),
        # Two names are enough to say "more than one root package".
        root_names = tuple(sorted(root_names.keys())[:2]),
        embedders = tuple(sorted(embedders.keys())),
        sky_engines = tuple(sorted(sky_engines.keys())),
        nested_roots = nested,
        code_assets = code_assets,
        unreplaced_hooks = unreplaced_hooks,
        merged = tuple(dep_labels),
    )

def facts_of(info):
    """The closure facts of a `DartInfo`, or None when it carries none.

    Args:
      info: A `DartInfo`.

    Returns:
      The facts struct, or None.
    """
    return getattr(info, "closure_facts", None)

def owner_keys(facts):
    """The closure's owner keys, one per distinct name and root, if each has one owner.

    Whether every package name and root has one owner is not a property that
    composes, so the two depsets are expanded and their lengths compared, in
    Java: each key has one owner exactly when there are as many distinct
    owner entries as distinct keys. The list then answers `name_key`/
    `root_key` membership with `in`, also in Java.

    Args:
      facts: A facts struct from `facts_of`.

    Returns:
      The list of keys, or None when some key has two owners.
    """
    # lint-allow: depset-flatten one owner per key does not compose from direct deps; expanded in Java, no Starlark loop
    keys = facts.owner_keys.to_list()
    # lint-allow: depset-flatten compared by length with the keys above, in Java, no Starlark loop
    if len(facts.owners.to_list()) != len(keys):
        return None
    return keys

def owners_unique(facts):
    """Whether every package name and every root of the closure has one owner.

    This is the one closure-sized step the summary aspect still takes per
    target; see `closure_owner_index` in `dart_analyzer_summary.bzl`.

    Args:
      facts: A facts struct from `facts_of`.

    Returns:
      A bool.
    """
    return owner_keys(facts) != None

def owner_index(facts):
    """Expands the owners once and indexes them by name and by root.

    The expansion and the `dict` are built in Java; no Starlark loop walks the
    closure. Used where a terminal consumer (an executable, or the analysis of
    one) has to look a package up by name or by root.

    Args:
      facts: A facts struct from `facts_of`.

    Returns:
      `struct(index, unique)`: `index` maps `name_key`/`root_key` to one owner
      string (see `owner_fields`), and `unique` says whether every name and
      every root has exactly one owner.
    """
    # lint-allow: depset-flatten terminal lookup by name or root; dict() is built in Java, no Starlark loop
    entries = facts.owners.to_list()
    index = dict(entries)
    return struct(index = index, unique = len(index) == len(entries))

def clean_closure(facts):
    """The owner index of a closure whose package records need no merging, else None.

    Clean means every package name and every root has one owner, no root
    sits inside another package's `lib/`, at most one package is the root
    package, and no record carries code assets. Then the closure's records
    are already one per name and agree with each other, a file belongs to the
    package of the one record whose `lib/` holds it, and a consumer can hand
    `transitive_packages` to its actions as it is.

    Args:
      facts: A facts struct from `facts_of`, or None.

    Returns:
      `struct(keys)`, the `owner_keys` list, which answers membership of a
      `name_key` or `root_key`; or None when the closure is not clean or the
      facts are missing.
    """
    if facts == None or facts.nested_roots or facts.code_assets or len(facts.root_names) > 1:
        return None
    keys = owner_keys(facts)
    if keys == None:
        return None
    return struct(keys = keys)

def lib_roots_of(short_path):
    """Every root whose package's `lib/` would contain a file, innermost first.

    Args:
      short_path: A `File.short_path`.

    Returns:
      The candidate `lib_root`s, deepest first: `a/b` for `a/b/lib/x.dart`,
      and `""` for a path under the root package's `lib/`.
    """
    parts = short_path.split("/")
    roots = []
    for i in range(len(parts) - 1):
        if parts[i] == "lib":
            roots.append("/".join(parts[:i]))
    return reversed(roots)

def roots_containing(short_path):
    """Every directory that could be a package root containing a file, innermost first.

    Args:
      short_path: A `File.short_path`.

    Returns:
      The candidate roots, deepest first, ending with `""`.
    """
    parts = short_path.split("/")
    return ["/".join(parts[:i]) for i in range(len(parts) - 1, 0, -1)] + [""]
