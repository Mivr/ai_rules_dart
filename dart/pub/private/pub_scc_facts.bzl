"""Lockfile facts cache for pub dependency-cycle planning.

Cycle planning needs every in-scope package's `dependencies:` names before any
repository is generated, so the extension downloads each package's archive (or
clones its git checkout) into scratch, checks it, and reads the one file it
needs, `pubspec.yaml` (see `//dart/pub:extensions.bzl`). That cost grows with
the number of pub dependencies and is paid again on every re-evaluation: the
extension is not reproducible, so its results live in `MODULE.bazel.lock`, and
a lock change, a rules_dart upgrade, or `--lockfile_mode=off` re-evaluates it.

To skip the repeated work the extension records, per planned package, the
sorted dependency names planning took from that package's `pubspec.yaml` —
exactly what `parse_pubspec_deps` returns, unfiltered — as extension facts.
Bazel stores them in the lockfile and hands them back as `module_ctx.facts`
on the next evaluation, so a package whose fact still applies is neither
downloaded nor cloned, extracted, walked, nor parsed. Planning consumes the
recorded names directly: each name is one edge, never rendered back into
pubspec text, so a name carrying quotes, newlines or colons cannot split
into several names.

Facts are hints, not pins. Every key carries the schema version plus a digest
of the pubspec parser's sources (`pub.scc.v2.<digest>/`), so facts written by
another version of the extension or another parser never collide: they are
simply never looked up, and the returned facts — built fresh each evaluation
holding exactly the packages it planned — drop them. A fact whose key matches
but whose value is malformed (not a list of strings) fails the evaluation
naming the key, rather than planning from invented edges. A fact whose names
disagree with the package's real pubspec fails the merged repository that
fetches it (see `//dart/pub/private:pub_scc_verify.bzl`).

This module holds the pure facts logic (parser digest, key building, lookup,
validation, the split into hits and misses, and the returned dict) plus the
narrowed scratch check, so Starlark unit tests cover them without a context.
The context-touching halves — the fetch orchestration in
`//dart/pub:extensions.bzl` and `read_scope_pubspec` below — stay thin
wrappers over these.

Facts only change the extension's own planning input. The spokes (hosted,
git, and merged-cycle repositories) still fetch by the lock's sha256 or ref,
still refuse hostile archive headers before extracting, and still run the
full `check_package_symlinks` walk.
"""

load("//dart/pub/private:pub_symlink.bzl", "pub_symlink_error", "realpath_escapes_root")

# Fixed schema version carried in every fact key alongside the parser digest.
# Keys from another schema are never looked up, so Bazel shallow-merging facts
# dicts across extension versions cannot mix values: a key uniquely determines
# its value within one schema.
_PUB_SCC_FACTS_SCHEMA_VERSION = "pub.scc.v2"

_HEX_DIGITS = "0123456789abcdef"

def _normalize_parser_text(text):
    """Normalises parser source bytes before hashing, so CRLF and LF checkouts key alike."""
    return text.replace("\r\n", "\n").replace("\r", "\n")

def _hex8(value):
    """Formats the low 32 bits of `value` as 8 lowercase hex digits."""
    v = value % 4294967296
    if v < 0:
        v += 4294967296
    out = ""
    for _ in range(8):
        out = _HEX_DIGITS[v % 16] + out
        v = v // 16
    return out

def parser_texts_digest(parser_texts):
    """Digests parser source texts to a hex string of at least 64 bits.

    The normalised texts are length-prefixed and joined, then hashed twice:
    once directly and once over a domain-separated transform, plus the
    combined length. Any one-byte change in any text changes the digest, so
    every fact key changes; anything but the parser sources leaves it alone.

    Args:
      parser_texts: The parser source files' contents, in canonical order
        (the extension passes its parser labels' bytes in label order).

    Returns:
      24 lowercase hex digits.
    """
    combined = ""
    for text in parser_texts:
        normalized = _normalize_parser_text(text)
        combined += str(len(normalized)) + "\n" + normalized + "\n"
    first = hash(combined)
    second = hash("pub.scc.parser\n" + combined)
    return _hex8(first) + _hex8(second) + _hex8(len(combined))

def parser_schema(parser_texts):
    """Builds this evaluation's fact-key schema from the parser sources' bytes.

    The fixed version keeps facts from another extension generation apart;
    the digest re-derives every fact when the pubspec parser changes, so
    facts the old parser recorded are never reused.

    Args:
      parser_texts: The parser source files' contents, in canonical order.

    Returns:
      The schema prefix every fact key of this evaluation carries.
    """
    return _PUB_SCC_FACTS_SCHEMA_VERSION + "." + parser_texts_digest(parser_texts)

def hosted_fact_key(package_name, version, sha256, schema):
    """Builds the fact key for a hosted package's recorded pubspec deps.

    Args:
      package_name: The pub package name.
      version: The resolved version planning used.
      sha256: The lock's archive sha256 planning pinned.
      schema: This evaluation's `parser_schema`, binding the key to the
        pubspec parser's sources.

    Returns:
      The opaque fact key. Any change of version, sha256, or parser sources
      is another key, hence a miss that falls back to a fetch.
    """
    return schema + "/hosted/" + package_name + "/" + version + "/" + sha256

def git_fact_key(package_name, resolved_ref, path, schema):
    """Builds the fact key for a git package's recorded pubspec deps.

    Args:
      package_name: The pub package name.
      resolved_ref: The resolved commit ref planning pinned.
      path: The in-repo path holding the package.
      schema: This evaluation's `parser_schema`, binding the key to the
        pubspec parser's sources.

    Returns:
      The opaque fact key. Any change of ref, path, or parser sources is
      another key, hence a miss that falls back to a fetch.
    """
    return schema + "/git/" + package_name + "/" + resolved_ref + "/" + path

def fact_deps_error(key, value):
    """Validates one fact value read back from the lockfile.

    Args:
      key: The current-schema fact key the value was read under, for
        diagnostics.
      value: The raw fact value.

    Returns:
      An error string naming the key when the value is malformed (not a
      list of strings), or None when the value is usable.
    """
    if type(value) != "list":
        return "pub scc facts: fact %r is malformed: expected a list of dependency names" % key
    for dep in value:
        if type(dep) != "string":
            return "pub scc facts: fact %r is malformed: expected a list of dependency names" % key
    return None

def lookup_fact_deps(facts, key):
    """Looks up one package's recorded deps, failing closed on malformed facts.

    Reads through `.get` only, so both the `Facts` object a module extension
    sees and the plain dicts unit tests pass work.

    Args:
      facts: The lockfile facts mapping.
      key: The current-schema fact key for the package being planned.

    Returns:
      The sorted recorded dep names on a hit, or None on a miss (no fact
      under the key). A fact under the key whose value is malformed fails
      the evaluation with a diagnostic naming the key.
    """
    value = facts.get(key, None)
    if value == None:
        return None
    err = fact_deps_error(key, value)
    if err:
        fail(err)
    return sorted(value)

def split_scope_facts(facts, hosted, git_pkgs, schema):
    """Splits one scope's packages into fact hits and fetch misses.

    Args:
      facts: The lockfile facts mapping.
      hosted: Dict of hosted package name to
        `struct(version, sha256, url)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path)`.
      schema: This evaluation's `parser_schema`, binding every key to the
        pubspec parser's sources.

    Returns:
      `struct(deps, keys, hosted_miss, git_miss)`: `deps` maps every hit
      package name to its sorted recorded dep names; `keys` maps every
      in-scope package name (hits and misses) to the fact key it was looked
      up under, for recording; `hosted_miss`/`git_miss` hold the packages
      with no applicable fact, to fetch as today.
    """
    wanted = {}
    for name in sorted(hosted.keys()):
        pkg = hosted[name]
        wanted[name] = hosted_fact_key(name, pkg.version, pkg.sha256, schema)
    for name in sorted(git_pkgs.keys()):
        pkg = git_pkgs[name]
        wanted[name] = git_fact_key(name, pkg.resolved_ref, pkg.path, schema)
    deps = {}
    miss = []
    for name in sorted(wanted.keys()):
        hit = lookup_fact_deps(facts, wanted[name])
        if hit == None:
            miss.append(name)
        else:
            deps[name] = hit
    return struct(
        deps = deps,
        keys = wanted,
        hosted_miss = {name: hosted[name] for name in miss if name in hosted},
        git_miss = {name: git_pkgs[name] for name in miss if name in git_pkgs},
    )

def record_scope_facts(recorded, split, miss_deps):
    """Records one scope's planned packages into the facts to return.

    Hits re-record what the lockfile said; misses record the sorted names one
    pubspec parse took — the same result planning consumes — so a pubspec that
    fails `parse_pubspec_deps` still fails the evaluation and records nothing.
    Building the dict fresh each evaluation — exactly the packages planned,
    nothing else — drops foreign-schema and stale entries.

    Args:
      recorded: Dict receiving fact key to sorted dep names. Mutated in
        place, shared across the evaluation's scopes.
      split: The `split_scope_facts` result for this scope.
      miss_deps: Dict of missed package name to its sorted dependency names,
        parsed once from the freshly fetched pubspec.
    """
    for name in sorted(split.keys.keys()):
        if name in split.deps:
            recorded[split.keys[name]] = split.deps[name]
        else:
            recorded[split.keys[name]] = miss_deps[name]

def scratch_pubspec_error(check):
    """Decides one scope-scratch `pubspec.yaml` read without touching the tree.

    The extension reads exactly one file per fetched package, so its scratch
    check covers exactly that: the package root itself and the `pubspec.yaml`
    entry. Anything else in the archive may pass here; the spokes re-fetch
    the same bytes and still run the full walk.

    Args:
      check: A struct with `package_name`, `root_expected_str` (the package
        root's path through its resolved parent), `root_real_str` (the root's
        canonical target), `pubspec_rel` (the pubspec path relative to the
        root, for diagnostics), `exists` (whether the pubspec entry
        resolves), `listed` (whether its name appears in the root listing,
        telling a dangling symlink apart from a missing file), and `real_str`
        (the pubspec's canonical target when it resolves).

    Returns:
      A `pub_symlink_error` diagnostic naming the package when the root does
      not resolve to itself, the pubspec is a dangling symlink or link loop,
      or its target lies outside the root; None when the read may proceed
      (a missing pubspec reads as "").
    """
    if check.root_real_str != check.root_expected_str:
        return pub_symlink_error(check.package_name, ".", check.root_real_str)
    if not check.exists:
        if check.listed:
            return pub_symlink_error(check.package_name, check.pubspec_rel, "(broken symlink)")
        return None
    if realpath_escapes_root(check.root_real_str, check.real_str):
        return pub_symlink_error(check.package_name, check.pubspec_rel, check.real_str)
    return None

def read_scope_pubspec(ctx, package_name, out):
    """Reads one fetched scope package's `pubspec.yaml` under the narrowed check.

    Args:
      ctx: The module extension context.
      package_name: The pub package being planned, for diagnostics.
      out: The scratch directory the package was extracted into.

    Returns:
      The `pubspec.yaml` contents ("" when the package ships none), following
      a link that resolves inside the package. Fails with today's
      `pub_symlink_error` diagnostic when the root does not resolve to
      itself, the pubspec dangles or loops, or its target escapes the root.
      Uses only Bazel's path and repository APIs, never host tools.
    """
    root = ctx.path(out)
    if not root.exists or not root.is_dir:
        return ""
    parent, _, base = out.rpartition("/")
    if parent == "":
        parent = "."
    pubspec = out + "/pubspec.yaml"
    entry = ctx.path(pubspec)
    found = entry.exists
    real_str = str(entry.realpath) if found else ""
    listed = False
    if not found:
        for child in root.readdir():
            if child.basename == "pubspec.yaml":
                listed = True
    err = scratch_pubspec_error(struct(
        package_name = package_name,
        root_expected_str = str(ctx.path(parent).realpath) + "/" + base,
        root_real_str = str(root.realpath),
        pubspec_rel = "pubspec.yaml",
        exists = found,
        listed = listed,
        real_str = real_str,
    ))
    if err:
        fail(err)
    if not found:
        return ""
    return ctx.read(pubspec)
