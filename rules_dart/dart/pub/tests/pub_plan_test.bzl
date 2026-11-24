"""Tests for planning the pub graph from the hosted API and for per-repository attributes.

Planning reads `GET <base>/api/packages/<name>` listings (here served by a
stand-in context that answers downloads from a dict), picks the locked
versions, checks the listing's hash against the lock's, and hands what the
server cannot answer for to the archive fallback. The emitted repositories'
attributes depend only on each package's own entry: the last tests resolve
locks that differ in one entry and compare every repository spec.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:extensions.bzl", "resolve_pub_packages")
load("//dart/pub/private:package_graph.bzl", "builder_packages")
load("//dart/pub/private:pub_emit.bzl", "pub_repo_specs")
load("//dart/pub/private:pub_lock_hub.bzl", "hub_files_error")
load(
    "//dart/pub/private:pub_plan.bzl",
    "hosted_plan_key",
    "plan_fact_error",
    "plan_from_listing",
    "plan_from_listings",
    "plan_pub_graph",
    "read_pub_plans",
)
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

_SHA_A = "a" * 64
_SHA_B = "b" * 64
_BASE = "https://pub.example"

def _version(version, deps = {}, sha = None, archive_url = None, sdk = "^3.0.0"):
    entry = {
        "version": version,
        "pubspec": {"name": "pkg", "version": version, "environment": {"sdk": sdk}, "dependencies": deps},
    }
    if sha != None:
        entry["archive_sha256"] = sha
    if archive_url != None:
        entry["archive_url"] = archive_url
    return entry

def _listing(*versions):
    return {"name": "pkg", "versions": list(versions)}

def _fake_ctx(listings, facts = {}):
    """A module context whose downloads answer from `listings` (URL to document).

    A URL missing from `listings` fails like a 404; a value that is a string
    is served as the raw body.
    """
    requests = []
    files = {}

    def wait_ok():
        return struct(success = True)

    def wait_failed():
        return struct(success = False, error = "404")

    def download(url, output, headers = {}, allow_fail = False, block = True):
        requests.append(struct(url = url, headers = headers, allow_fail = allow_fail, block = block))
        if url not in listings:
            return struct(wait = wait_failed)
        body = listings[url]
        files[output] = body if type(body) == "string" else json.encode(body)
        return struct(wait = wait_ok)

    def read(path, watch = "auto"):
        return files[path]

    return struct(download = download, read = read, facts = facts, requests = requests)

def _hosted(name, version, sha = _SHA_A, url = _BASE):
    return struct(name = name, pkg = struct(version = version, sha256 = sha, url = url))

def _plan_from_listing_test_impl(ctx):
    env = unittest.begin(ctx)
    listing = _listing(
        _version("1.0.0", deps = {"old": "^1.0.0"}, sha = _SHA_B),
        _version("1.1.0", deps = {"zeta": "any", "alpha": "^2.0.0"}, sha = _SHA_A, archive_url = "https://cdn.example/pkg-1.1.0.tar.gz", sdk = ">=3.2.0 <4.0.0"),
    )
    result = plan_from_listing(listing, "pkg", "1.1.0", _SHA_A, _BASE)
    asserts.equals(env, None, result.error)
    asserts.equals(env, None, result.fallback)
    asserts.equals(
        env,
        {"deps": ["alpha", "zeta"], "sdk": ">=3.2.0 <4.0.0", "archive_url": "https://cdn.example/pkg-1.1.0.tar.gz"},
        result.plan,
        "the locked version's sorted dependency names, SDK constraint and the listed archive URL",
    )
    no_url = plan_from_listing(_listing(_version("2.0.0", sha = _SHA_A)), "pkg", "2.0.0", _SHA_A, _BASE + "/")
    asserts.equals(env, "https://pub.example/packages/pkg/versions/2.0.0.tar.gz", no_url.plan["archive_url"], "no archive_url: the server's conventional archive path")
    asserts.equals(env, [], no_url.plan["deps"])
    return unittest.end(env)

def _hash_mismatch_test_impl(ctx):
    env = unittest.begin(ctx)
    result = plan_from_listing(_listing(_version("1.0.0", sha = _SHA_B)), "pkg", "1.0.0", _SHA_A, _BASE)
    asserts.equals(env, None, result.plan)
    asserts.true(env, result.error != None, "a listing hash that contradicts the lock fails")
    asserts.true(env, _SHA_A in result.error and _SHA_B in result.error, "the failure names both hashes: %s" % result.error)
    asserts.true(env, '"pkg" 1.0.0' in result.error, "the failure names the package and version: %s" % result.error)
    upper = plan_from_listing(_listing(_version("1.0.0", sha = _SHA_A.upper())), "pkg", "1.0.0", _SHA_A, _BASE)
    asserts.equals(env, None, upper.error, "hex case is not a mismatch")
    return unittest.end(env)

def _no_hash_test_impl(ctx):
    env = unittest.begin(ctx)
    result = plan_from_listing(_listing(_version("1.0.0", deps = {"meta": "any"})), "pkg", "1.0.0", _SHA_A, _BASE)
    asserts.equals(env, None, result.error)
    asserts.equals(env, ["meta"], result.plan["deps"], "a server that lists no archive_sha256 still plans; the lock's hash pins the archive")
    return unittest.end(env)

def _fallback_test_impl(ctx):
    env = unittest.begin(ctx)
    missing = plan_from_listing(_listing(_version("1.0.0", sha = _SHA_A)), "pkg", "1.0.1", _SHA_A, _BASE)
    asserts.equals(env, None, missing.plan)
    asserts.equals(env, None, missing.error)
    asserts.equals(env, "version 1.0.1 not listed", missing.fallback)
    for bad in [None, [], {"versions": "x"}, _listing({"version": "1.0.0", "pubspec": "text"})]:
        r = plan_from_listing(bad, "pkg", "1.0.0", _SHA_A, _BASE)
        asserts.true(env, r.plan == None and r.error == None and r.fallback != None, "falls back for %r" % (bad,))

    # Through the request loop: a 404, a missing version and a body that is
    # not JSON go to the archive fallback; the listed one plans.
    fake = _fake_ctx({
        _BASE + "/api/packages/listed": _listing(_version("1.0.0", sha = _SHA_A)),
        _BASE + "/api/packages/stale": _listing(_version("1.0.0", sha = _SHA_A)),
        _BASE + "/api/packages/garbled": "<html>not json</html>",
    })
    miss = {
        "k_listed": _hosted("listed", "1.0.0"),
        "k_stale": _hosted("stale", "2.0.0"),
        "k_garbled": _hosted("garbled", "1.0.0"),
        "k_gone": _hosted("gone", "1.0.0"),
    }
    result = plan_from_listings(fake, miss)
    asserts.equals(env, ["k_listed"], sorted(result.plans.keys()))
    asserts.equals(env, ["k_garbled", "k_gone", "k_stale"], sorted(result.fallback.keys()))
    for request in fake.requests:
        asserts.false(env, request.block, "listing requests do not block")
        asserts.true(env, request.allow_fail, "a failed listing falls back instead of failing")
        asserts.equals(env, "application/vnd.pub.v2+json", request.headers.get("Accept"))
    return unittest.end(env)

def _one_request_per_name_test_impl(ctx):
    env = unittest.begin(ctx)
    listing_url = _BASE + "/api/packages/pkg"
    fake = _fake_ctx({
        listing_url: _listing(
            _version("1.0.0", deps = {"a": "any"}, sha = _SHA_A),
            _version("2.0.0", deps = {"b": "any"}, sha = _SHA_B),
        ),
    })
    scopes = [
        struct(hosted = {"pkg": struct(version = "1.0.0", sha256 = _SHA_A, url = _BASE)}, git = {}),
        struct(hosted = {"pkg": struct(version = "2.0.0", sha256 = _SHA_B, url = _BASE)}, git = {}),
    ]
    recorded = {}
    plans = plan_pub_graph(fake, scopes, recorded)
    asserts.equals(env, [listing_url], [r.url for r in fake.requests], "two locked versions of one name: one listing request")
    asserts.equals(env, ["a"], plans[0]["pkg"]["deps"])
    asserts.equals(env, ["b"], plans[1]["pkg"]["deps"])
    asserts.equals(env, 2, len(recorded), "one fact per package version")
    key = hosted_plan_key("pkg", "1.0.0", _SHA_A, _BASE)
    asserts.equals(env, {"deps": ["a"], "sdk": "^3.0.0", "archive_url": _BASE + "/packages/pkg/versions/1.0.0.tar.gz"}, recorded[key])

    # The facts of that evaluation answer the next one without a request.
    again = _fake_ctx({}, facts = recorded)
    recorded_again = {}
    asserts.equals(env, plans, plan_pub_graph(again, scopes, recorded_again))
    asserts.equals(env, [], again.requests, "every fact hits: no request")
    asserts.equals(env, recorded, recorded_again, "hits are recorded again")
    return unittest.end(env)

def _fact_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, plan_fact_error("k", {"deps": ["a"], "sdk": "", "archive_url": "u"}, True))
    asserts.equals(env, None, plan_fact_error("k", {"deps": [], "sdk": ""}, False))
    for bad in [["a"], {"deps": "a", "sdk": "", "archive_url": "u"}, {"deps": [], "sdk": None, "archive_url": "u"}, {"deps": [], "sdk": ""}]:
        err = plan_fact_error("the-key", bad, True)
        asserts.true(env, err != None and "the-key" in err, "a malformed fact names its key: %r" % (bad,))
    return unittest.end(env)

def _shipped_plan_test_impl(ctx):
    env = unittest.begin(ctx)
    key = hosted_plan_key("pkg", "1.0.0", _SHA_A, _BASE)
    plan = {"deps": ["a"], "sdk": "^3.0.0", "archive_url": _BASE + "/archive.tar.gz"}
    plan_file = json.encode({"schema": "pub.plan.v1", "plans": {
        key: plan,
        "pub.plan.v0/hosted/old/1.0.0/x/y": {"deps": 1},
    }})
    fake = struct(read = lambda label, watch = "auto": plan_file)
    shipped = read_pub_plans(fake, ["//:plan.json"])
    asserts.equals(env, {key: plan}, shipped, "a key of another schema is skipped")

    scopes = [struct(hosted = {
        "pkg": struct(version = "1.0.0", sha256 = _SHA_A, url = _BASE),
        "other": struct(version = "2.0.0", sha256 = _SHA_B, url = _BASE),
    }, git = {})]
    fake = _fake_ctx({_BASE + "/api/packages/other": _listing(_version("2.0.0", sha = _SHA_B))})
    recorded = {}
    plans = plan_pub_graph(fake, scopes, recorded, shipped)
    asserts.equals(env, plan, plans[0]["pkg"], "the shipped plan answers")
    asserts.equals(env, [_BASE + "/api/packages/other"], [r.url for r in fake.requests], "only the package the plan misses is requested")
    asserts.equals(env, [hosted_plan_key("other", "2.0.0", _SHA_B, _BASE)], sorted(recorded.keys()), "a shipped plan is not recorded as a fact")

    asserts.equals(env, {}, read_pub_plans(fake, []), "no file, no plan")
    return unittest.end(env)

def _hub_files_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, hub_files_error({"android/BUILD.bazel": "", "packages.bzl": "", "a/b.json": "{}"}))
    for bad in ["BUILD.bazel", "/abs", "../up", "a/../b", "a//b", "./a", "a\\b", "REPO.bazel"]:
        err = hub_files_error({bad: ""})
        asserts.true(env, err != None and repr(bad) in err, "refused: %r" % bad)
    return unittest.end(env)

# One-entry lock changes and the repository specs they produce.

def _lock_entry(version, sha):
    return {
        "source": "hosted",
        "version": version,
        "dependency": "transitive",
        "description": {"name": "x", "sha256": sha, "url": "https://pub.dev"},
    }

# package -> (version, sha, deps)
_GRAPH = {
    "app_dep": ("1.0.0", "1" * 64, ["mid", "meta"]),
    "mid": ("2.0.0", "2" * 64, ["leaf", "meta"]),
    "leaf": ("3.0.0", "3" * 64, []),
    "meta": ("1.16.0", "4" * 64, []),
    "cyc_a": ("1.0.0", "5" * 64, ["cyc_b"]),
    "cyc_b": ("1.0.0", "6" * 64, ["cyc_a", "meta"]),
}

def _specs(graph):
    resolution = resolve_pub_packages([], [struct(
        name = "pub_deps",
        lock = "//:pubspec.lock",
        packages = {name: _lock_entry(v[0], v[1]) for name, v in graph.items()},
        on_version_conflict = "error",
        isolated = False,
    )])
    if resolution.error:
        fail(resolution.error)
    plans = {
        name: {"deps": sorted(v[2]), "sdk": "^3.0.0", "archive_url": "https://pub.dev/api/archives/%s-%s.tar.gz" % (name, v[0])}
        for name, v in graph.items()
    }
    specs = pub_repo_specs(resolution, [plans], {})
    return {name: json.encode(struct(rule = s.rule, attrs = s.attrs)) for name, s in specs.items()}

def _diff(before, after):
    return struct(
        added = sorted([n for n in after if n not in before]),
        removed = sorted([n for n in before if n not in after]),
        changed = sorted([n for n in after if n in before and after[n] != before[n]]),
    )

def _one_entry_one_repository_test_impl(ctx):
    env = unittest.begin(ctx)
    base = _specs(_GRAPH)
    asserts.true(env, "dart_pub__scc__cyc_a__cyc_b" in base, "the cycle merges: %s" % sorted(base.keys()))

    bumped = dict(_GRAPH)
    bumped["leaf"] = ("3.0.1", "7" * 64, [])
    d = _diff(base, _specs(bumped))
    asserts.equals(env, [], d.added)
    asserts.equals(env, [], d.removed)
    asserts.equals(env, ["dart_pub__leaf", "pub_deps"], d.changed, "a version bump changes that package's repository, and the hub's package graph")

    added = dict(_GRAPH)
    added["zed"] = ("0.1.0", "8" * 64, ["meta"])
    d = _diff(base, _specs(added))
    asserts.equals(env, ["dart_pub__zed"], d.added, "one package added: one new repository")
    asserts.equals(env, [], d.removed)
    asserts.equals(env, ["pub_deps"], d.changed, "no package repository changes; the hub gains the alias")

    removed = dict(_GRAPH)
    removed.pop("app_dep")
    d = _diff(base, _specs(removed))
    asserts.equals(env, ["dart_pub__app_dep"], d.removed)
    asserts.equals(env, [], d.added)
    asserts.equals(env, ["pub_deps"], d.changed, "removing a package changes no other package repository")

    member = dict(_GRAPH)
    member["cyc_b"] = ("1.0.1", "9" * 64, ["cyc_a", "meta"])
    d = _diff(base, _specs(member))
    asserts.equals(env, ["dart_pub__scc__cyc_a__cyc_b", "pub_deps"], d.changed, "a cycle member's change changes its cycle's repository, and the hub's package graph")
    return unittest.end(env)

def _hub_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    hub = json.decode(_specs(_GRAPH)["pub_deps"])["attrs"]
    graph = json.decode(hub["package_graph"])
    asserts.equals(env, [], graph["roots"], "the user's own packages are not in a lock")
    by_name = {p["name"]: p for p in graph["packages"]}
    asserts.equals(env, sorted(_GRAPH.keys()), sorted(by_name.keys()), "every package of the lock")
    for name, v in _GRAPH.items():
        asserts.equals(env, v[0], by_name[name]["version"])
        asserts.equals(env, sorted(v[2]), by_name[name]["dependencies"], name)
        asserts.equals(env, [], by_name[name]["devDependencies"])
    asserts.equals(env, "", hub["build_runner_version"], "no build_runner in this lock")
    return unittest.end(env)

def _builder_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    names = ["build", "source_gen", "gen_a", "gen_b", "gen_flutter", "uses_gen_flutter", "plain"]
    deps = {
        "build": [],
        "source_gen": ["build"],
        "gen_a": ["build", "plain"],
        "gen_b": ["source_gen"],
        "gen_flutter": ["build", "flutter"],
        "uses_gen_flutter": ["gen_flutter", "source_gen"],
        "plain": [],
    }
    labels = {n: "@r__%s//:%s.build_yaml" % (n, n) for n in names}
    asserts.equals(
        env,
        {
            "gen_a": "@r__gen_a//:gen_a.build_yaml",
            "gen_b": "@r__gen_b//:gen_b.build_yaml",
            "source_gen": "@r__source_gen//:source_gen.build_yaml",
        },
        builder_packages(names, deps, labels),
        "packages on the builder API whose closure stays in the lock; one reaching an SDK package, directly or not, is left out",
    )
    return unittest.end(env)

def _own_attributes_test_impl(ctx):
    env = unittest.begin(ctx)
    resolution = resolve_pub_packages([], [struct(
        name = "pub_deps",
        lock = "//:pubspec.lock",
        packages = {name: _lock_entry(v[0], v[1]) for name, v in _GRAPH.items()},
        on_version_conflict = "error",
        isolated = False,
    )])
    plans = {
        name: {"deps": sorted(v[2] + ["flutter"]), "sdk": "^3.0.0", "archive_url": "https://pub.dev/api/archives/%s.tar.gz" % name}
        for name, v in _GRAPH.items()
    }
    plans["leaf"] = {"deps": ["cyc_b"], "sdk": "", "archive_url": "https://pub.dev/api/archives/leaf.tar.gz"}
    specs = pub_repo_specs(resolution, [plans], {"dart_pub": {"mid": struct(
        user_defines = '{"source":"system"}',
        pubspec = "pubspec.yaml",
        data = ["@@//:mid.c"],
        network = False,
        source = "//:pubspec.lock",
    )}})
    mid = specs["dart_pub__mid"]
    asserts.equals(env, "pub_lock_package", mid.rule)
    asserts.equals(
        env,
        sorted(["package_name", "version", "sha256", "url", "planned_deps", "deps", "package_files", "hook_user_defines", "hook_pubspec", "hook_data", "hook_network"]),
        sorted(mid.attrs.keys()),
    )
    asserts.equals(env, ["@dart_pub__leaf//:leaf", "@dart_pub__meta//:meta"], mid.attrs["deps"], "own dependencies only; a name outside the lock (an SDK package) has no label")
    asserts.equals(env, ["flutter", "leaf", "meta"], mid.attrs["planned_deps"], "the whole planned list, for the fetch-time check")
    asserts.equals(env, "https://pub.dev/api/archives/mid.tar.gz", mid.attrs["url"])
    asserts.equals(env, '{"source":"system"}', mid.attrs["hook_user_defines"], "the package's own slice of `hooks.user_defines`")
    asserts.equals(env, ["@@//:mid.c"], mid.attrs["hook_data"])
    asserts.false(env, "hook_user_defines" in specs["dart_pub__leaf"].attrs, "a package with no settings gets none")
    merged = specs["dart_pub__scc__cyc_a__cyc_b"]
    asserts.equals(env, ["members_json", "repo_name"], sorted(merged.attrs.keys()))
    members = {m["name"]: m for m in json.decode(merged.attrs["members_json"])}
    asserts.equals(env, [], members["cyc_a"]["deps"], "an edge inside the cycle is no label")
    asserts.equals(env, ["@dart_pub__meta//:meta"], members["cyc_b"]["deps"], "an edge leaving the cycle is its label")
    asserts.equals(env, ["cyc_b", "flutter"], members["cyc_a"]["planned_deps"])
    asserts.false(env, "dart_pub__cyc_a" in specs, "a cycle member has no spoke of its own")
    asserts.equals(env, ["@dart_pub__scc__cyc_a__cyc_b//:cyc_b"], specs["dart_pub__leaf"].attrs["deps"], "an edge into a cycle names the merged repository")
    return unittest.end(env)

_plan_from_listing_test = unittest.make(_plan_from_listing_test_impl)
_hash_mismatch_test = unittest.make(_hash_mismatch_test_impl)
_no_hash_test = unittest.make(_no_hash_test_impl)
_fallback_test = unittest.make(_fallback_test_impl)
_one_request_per_name_test = unittest.make(_one_request_per_name_test_impl)
_fact_shape_test = unittest.make(_fact_shape_test_impl)
_one_entry_one_repository_test = unittest.make(_one_entry_one_repository_test_impl)
_own_attributes_test = unittest.make(_own_attributes_test_impl)
_shipped_plan_test = unittest.make(_shipped_plan_test_impl)
_hub_files_test = unittest.make(_hub_files_test_impl)
_hub_graph_test = unittest.make(_hub_graph_test_impl)
_builder_packages_test = unittest.make(_builder_packages_test_impl)

def pub_plan_test_suite(name):
    small_unittest_suite(
        name,
        _plan_from_listing_test,
        _hash_mismatch_test,
        _no_hash_test,
        _fallback_test,
        _one_request_per_name_test,
        _fact_shape_test,
        _one_entry_one_repository_test,
        _own_attributes_test,
        _shipped_plan_test,
        _hub_files_test,
        _hub_graph_test,
        _builder_packages_test,
    )
