"""Plans the pub package graph from the hosted API's listing JSON.

The `pub` extension needs every package's dependency names before it
generates a repository: they decide the dependency cycles to merge and each
repository's own dependency labels. A hosted server answers that without the
archive: `GET <base>/api/packages/<name>` (what `dart pub` itself reads)
lists every version of the package with its pubspec, its `archive_url` and,
usually, its `archive_sha256`. The extension starts one non-blocking request
per distinct package name of the evaluation, decodes each listing once and
picks the locked versions; no archive is downloaded while planning.

What one package version plans to is recorded as an extension fact, so a
re-evaluation that finds it issues no request. The key carries the package
name, the locked version and sha256, the server and a schema number: nothing
a later evaluation can change without changing the key, so a fact never
expires. The value is the sorted dependency names, the SDK constraint and
the archive URL.

Integrity: the archive a build fetches is pinned by the lock's sha256, as it
always was. A listing that carries `archive_sha256` must agree with the lock,
or the evaluation fails naming both. A listing that carries none still
plans: the spoke that fetches the package compares its real `pubspec.yaml`
with the planned names (`pub_scc_verify.bzl`) and fails on a difference, so
the listing's metadata is checked against the archive it describes.

Fallback: a package the server cannot answer for (no listing, the version
missing from it, a listing that is not JSON) is planned from its archive, as
before: downloaded in parallel with the other fallbacks, scanned, extracted,
and its `pubspec.yaml` converted with the other pubspecs in one `yaml2json` call.
Git packages have no API: they are cloned and read the same way.
"""

load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub/private:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("//dart/pub/private:pub_lock_package.bzl", "trim_gzip_trailing_nulls")
load("//dart/pub/private:pub_scan.bzl", "run_pub_archive_scans")
load("//dart/pub/private:pub_scc_facts.bzl", "scope_pubspec_path")
load("//dart/pub/private:pubspec_data.bzl", "pubspec_deps", "pubspec_sdk_constraint")
load("//dart/pub/private:yaml2json.bzl", "yaml_to_json")

visibility(["//dart/..."])

# Carried in every plan fact key. Bump it when the fact value changes shape
# or meaning; keys of another schema are never looked up.
PLAN_FACTS_SCHEMA = "pub.plan.v1"

_API_HEADERS = {"Accept": "application/vnd.pub.v2+json"}

_SCRATCH = "_pub_plan"

def hosted_plan_key(name, version, sha256, base_url):
    """Builds the fact key for one hosted package version.

    Args:
      name: The package name.
      version: The locked version.
      sha256: The lock's archive sha256.
      base_url: The lock entry's `description.url`, the server the package
        comes from (it decides the archive URL the fact records).

    Returns:
      The fact key.
    """
    return "%s/hosted/%s/%s/%s/%s" % (PLAN_FACTS_SCHEMA, name, version, sha256, base_url)

def git_plan_key(name, resolved_ref, path):
    """Builds the fact key for one git package.

    Args:
      name: The package name.
      resolved_ref: The locked commit.
      path: The package's directory inside the repository.

    Returns:
      The fact key.
    """
    return "%s/git/%s/%s/%s" % (PLAN_FACTS_SCHEMA, name, resolved_ref, path)

def listing_url(base_url, name):
    """The hosted API listing of one package: every version with its pubspec.

    Args:
      base_url: The server, from the lock entry's `description.url`.
      name: The package name.

    Returns:
      The listing URL.
    """
    return "%s/api/packages/%s" % (base_url.rstrip("/"), name)

def fallback_archive_url(base_url, name, version):
    """The archive URL used when the server's listing gives none.

    Args:
      base_url: The server, from the lock entry's `description.url`.
      name: The package name.
      version: The locked version.

    Returns:
      The archive URL.
    """
    return "%s/packages/%s/versions/%s.tar.gz" % (base_url.rstrip("/"), name, version)

def _is_string_list(value):
    if type(value) != "list":
        return False
    for item in value:
        if type(item) != "string":
            return False
    return True

def plan_fact_error(key, value, hosted):
    """Validates one plan fact read back from the lockfile.

    Args:
      key: The fact key, for the message.
      value: The recorded value.
      hosted: Whether the key is a hosted package's (its value must carry
        an archive URL).

    Returns:
      An error naming the key when the value is malformed, else None.
    """
    ok = (
        type(value) == "dict" and
        _is_string_list(value.get("deps")) and
        type(value.get("sdk")) == "string" and
        (not hosted or (type(value.get("archive_url")) == "string" and value["archive_url"] != ""))
    )
    if ok:
        return None
    return (
        "pub plan facts: fact %r is malformed: expected {\"deps\": [names], \"sdk\": constraint%s}. " +
        "Remove the pub extension's `facts` entry from MODULE.bazel.lock and build again."
    ) % (key, ", \"archive_url\": url" if hosted else "")

def _lookup(facts, key, hosted):
    """Returns the recorded plan for `key`, None on a miss; fails on a malformed one."""
    value = facts.get(key, None)
    if value == None:
        return None
    err = plan_fact_error(key, value, hosted)
    if err:
        fail(err)
    return {k: value[k] for k in (["deps", "sdk", "archive_url"] if hosted else ["deps", "sdk"])}

def listing_sha256_error(name, version, lock_sha256, listing_sha256, url):
    """The failure for a listing whose archive hash differs from the lock's.

    Args:
      name: The package name.
      version: The locked version.
      lock_sha256: The lock's sha256.
      listing_sha256: The listing's `archive_sha256`.
      url: The listing URL, for the message.

    Returns:
      The message.
    """
    return (
        "pub package \"%s\" %s: the lock pins sha256 %s, but the server's listing %s says the " +
        "archive's sha256 is %s. The lock and the server disagree about the archive; run `dart pub get` " +
        "to refresh the lock, or check the server."
    ) % (name, version, lock_sha256, url, listing_sha256)

def plan_from_listing(listing, name, version, sha256, base_url):
    """Plans one locked package version from its decoded listing.

    Args:
      listing: The decoded `GET <base>/api/packages/<name>` document, or
        None when there is none (the request failed or the body was not
        JSON).
      name: The package name.
      version: The locked version.
      sha256: The lock's archive sha256.
      base_url: The server, from the lock entry's `description.url`.

    Returns:
      `struct(plan, fallback, error)`: `plan` is `{"deps", "sdk",
      "archive_url"}` when the listing answers for the version; `fallback`
      names why the archive must be read instead when it does not; `error`
      is the failure when the listing's `archive_sha256` contradicts the
      lock.
    """
    if type(listing) != "dict" or type(listing.get("versions")) != "list":
        return struct(plan = None, fallback = "no usable listing", error = None)
    entry = None
    for candidate in listing["versions"]:
        if type(candidate) == "dict" and candidate.get("version") == version:
            entry = candidate
            break
    if entry == None:
        return struct(plan = None, fallback = "version %s not listed" % version, error = None)
    pubspec = entry.get("pubspec")
    if type(pubspec) != "dict":
        return struct(plan = None, fallback = "listing entry has no pubspec", error = None)
    listed_sha = entry.get("archive_sha256")
    if listed_sha != None and str(listed_sha).lower() != sha256:
        return struct(
            plan = None,
            fallback = None,
            error = listing_sha256_error(name, version, sha256, str(listed_sha), listing_url(base_url, name)),
        )
    archive_url = entry.get("archive_url")
    if type(archive_url) != "string" or archive_url == "":
        archive_url = fallback_archive_url(base_url, name, version)
    return struct(
        plan = {
            "deps": sorted(pubspec_deps(pubspec)),
            "sdk": pubspec_sdk_constraint(pubspec),
            "archive_url": archive_url,
        },
        fallback = None,
        error = None,
    )

def collect_plan_keys(scopes):
    """Collects the distinct package versions every scope needs planned.

    Args:
      scopes: List of structs with `hosted` (name to `struct(version,
        sha256, url)`) and `git` (name to `struct(version, url,
        resolved_ref, path)`).

    Returns:
      `struct(hosted, git, scope_keys)`: `hosted` and `git` map each fact
      key to its package (`struct(name, pkg)`); `scope_keys` holds, per
      scope, its package names mapped to their keys.
    """
    hosted = {}
    git = {}
    scope_keys = []
    for scope in scopes:
        keys = {}
        for name in sorted(scope.hosted.keys()):
            pkg = scope.hosted[name]
            key = hosted_plan_key(name, pkg.version, pkg.sha256, pkg.url)
            hosted[key] = struct(name = name, pkg = pkg)
            keys[name] = key
        for name in sorted(scope.git.keys()):
            pkg = scope.git[name]
            key = git_plan_key(name, pkg.resolved_ref, pkg.path)
            git[key] = struct(name = name, pkg = pkg)
            keys[name] = key
        scope_keys.append(keys)
    return struct(hosted = hosted, git = git, scope_keys = scope_keys)

def _check_pins(hosted_miss, git_miss):
    """Fails before any request when a package to plan is not pinned."""
    for key in sorted(hosted_miss.keys()):
        e = hosted_miss[key]
        err = pinned_source_error("hosted", e.name, e.pkg.version, sha256 = e.pkg.sha256, rule = "pub.from_lock")
        if err:
            fail(err)
    for key in sorted(git_miss.keys()):
        e = git_miss[key]
        err = pinned_source_error("git", e.name, e.pkg.version, resolved_ref = e.pkg.resolved_ref, rule = "pub.from_lock")
        if err:
            fail(err)

def plan_from_listings(ctx, hosted_miss):
    """Plans hosted packages from the server's listings, one request per name.

    Starts every listing request before waiting on any, so the requests run
    in parallel (Bazel's `--http_max_parallel_downloads`, 8 by default),
    then decodes one listing at a time and keeps only the locked versions.

    Args:
      ctx: The module extension context.
      hosted_miss: Fact key to `struct(name, pkg)` for the hosted packages
        no fact covers.

    Returns:
      `struct(plans, fallback)`: `plans` maps fact keys to plans;
      `fallback` maps the keys the server could not answer for to their
      package, to plan from the archive.
    """
    by_listing = {}
    for key in sorted(hosted_miss.keys()):
        e = hosted_miss[key]
        by_listing.setdefault(listing_url(e.pkg.url, e.name), []).append(key)
    pending = []
    for i, url in enumerate(sorted(by_listing.keys())):
        output = "%s/listing_%d.json" % (_SCRATCH, i)

        # The listing is metadata, not a package: it cannot be pinned, and
        # nothing from it reaches a build unchecked (see the module doc).
        # lint-allow: download-unpinned the API listing has no published hash; plans are verified against the pinned archive
        token = ctx.download(url = url, output = output, headers = _API_HEADERS, allow_fail = True, block = False)
        pending.append(struct(url = url, output = output, token = token))
    plans = {}
    fallback = {}
    for p in pending:
        listing = None
        if p.token.wait().success:
            listing = json.decode(ctx.read(p.output, watch = "no"), default = None)
        for key in by_listing[p.url]:
            e = hosted_miss[key]
            result = plan_from_listing(listing, e.name, e.pkg.version, e.pkg.sha256, e.pkg.url)
            if result.error:
                fail(result.error)
            if result.plan == None:
                fallback[key] = e
            else:
                plans[key] = result.plan
    return struct(plans = plans, fallback = fallback)

def _fetch_fallback_archives(ctx, hosted_fallback):
    """Downloads the fallback archives in parallel. Returns the pending entries."""
    started = []
    for i, key in enumerate(sorted(hosted_fallback.keys())):
        e = hosted_fallback[key]
        url = fallback_archive_url(e.pkg.url, e.name, e.pkg.version)
        archive = "%s/hosted_%d.tar.gz" % (_SCRATCH, i)
        token = pinned_download(ctx, url = url, output = archive, sha256 = e.pkg.sha256, block = False)
        started.append(struct(key = key, name = e.name, archive = archive, out = "%s/hosted_%d" % (_SCRATCH, i), url = url, token = token))
    pending = []
    for s in started:
        s.token.wait()
        raw = ctx.read(s.archive, watch = "no")
        trimmed = trim_gzip_trailing_nulls(raw)
        if trimmed != raw:
            ctx.file(s.archive, trimmed, executable = False)
        pending.append(s)
    return pending

def _fetch_git_checkouts(ctx, git_miss):
    """Clones each git package at its locked commit. Returns the pending entries."""
    pending = []
    for i, key in enumerate(sorted(git_miss.keys())):
        e = git_miss[key]
        pkg = e.pkg

        # Absolute paths: `--git-dir` and `-o` take absolute paths, so no
        # command depends on the working directory.
        bare_rel = "%s/git_%d_bare" % (_SCRATCH, i)
        what = 'pub.from_lock "%s"' % e.name
        git_transport_fetch(ctx, pkg.url, bare_rel, pkg.resolved_ref, what)
        archive = str(ctx.path("%s/git_%d.tar" % (_SCRATCH, i)))
        spec = pkg.resolved_ref if pkg.path == "." else pkg.resolved_ref + ":" + pkg.path
        git_materialize(ctx, bare_rel, pkg.resolved_ref, archive, spec, what)
        pending.append(struct(key = key, name = e.name, archive = archive, out = "%s/git_%d" % (_SCRATCH, i), url = None))
    return pending

def plan_from_archives(ctx, hosted_fallback, git_miss):
    """Plans packages from their archives: the hosted fallback and git packages.

    Every archive is scanned in one scanner run before the first is
    extracted, and every pubspec is converted in one `yaml2json` call. The
    repositories that fetch these packages later scan their own copies
    again: nothing decided here weakens their checks.

    Args:
      ctx: The module extension context.
      hosted_fallback: Fact key to `struct(name, pkg)` for hosted packages
        the server could not answer for.
      git_miss: Fact key to `struct(name, pkg)` for git packages no fact
        covers.

    Returns:
      Dict of fact key to plan (`archive_url` only for hosted packages).
    """
    pending = _fetch_fallback_archives(ctx, hosted_fallback) + _fetch_git_checkouts(ctx, git_miss)
    if not pending:
        return {}

    # The check runs before extraction: a hostile archive fails planning
    # here, not after its links land.
    run_pub_archive_scans(ctx, [struct(archive = p.archive, name = p.name) for p in pending])
    pubspecs = []
    plans = {}
    for p in pending:
        ctx.extract(p.archive, output = p.out)
        path = scope_pubspec_path(ctx, p.name, p.out)
        plans[p.key] = {"deps": [], "sdk": ""}
        if path != None:
            pubspecs.append(struct(key = p.key, name = p.name, path = path))
    data = yaml_to_json(ctx, [p.path for p in pubspecs], [p.name + "/pubspec.yaml" for p in pubspecs])
    for i in range(len(pubspecs)):
        plans[pubspecs[i].key] = {
            "deps": sorted(pubspec_deps(data[i])),
            "sdk": pubspec_sdk_constraint(data[i]),
        }
    for p in pending:
        if p.url != None:
            plans[p.key]["archive_url"] = p.url
    return plans

def plan_pub_graph(ctx, scopes, recorded):
    """Plans every scope's packages: facts first, then listings, then archives.

    Args:
      ctx: The module extension context.
      scopes: List of structs with `hosted` and `git` package dicts (see
        `collect_plan_keys`).
      recorded: Dict receiving this evaluation's facts (fact key to plan).
        Built fresh, so it holds exactly the packages planned now.

    Returns:
      One dict per scope, in order, of package name to its plan
      (`{"deps", "sdk"}`, plus `"archive_url"` for hosted packages).
    """
    keys = collect_plan_keys(scopes)
    plans = {}
    hosted_miss = {}
    git_miss = {}
    for key in sorted(keys.hosted.keys()):
        hit = _lookup(ctx.facts, key, True)
        if hit == None:
            hosted_miss[key] = keys.hosted[key]
        else:
            plans[key] = hit
    for key in sorted(keys.git.keys()):
        hit = _lookup(ctx.facts, key, False)
        if hit == None:
            git_miss[key] = keys.git[key]
        else:
            plans[key] = hit
    _check_pins(hosted_miss, git_miss)
    listed = plan_from_listings(ctx, hosted_miss)
    plans.update(listed.plans)
    plans.update(plan_from_archives(ctx, listed.fallback, git_miss))
    for key in sorted(plans.keys()):
        recorded[key] = plans[key]
    return [
        {name: plans[key] for name, key in scope_keys.items()}
        for scope_keys in keys.scope_keys
    ]
