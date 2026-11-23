"""Tests for how `pub.from_lock` serves each source a lock can hold.

The inputs are lock entries in the shape stock `dart pub get` writes them (see
the `path`, `sdk`, `git` and override entries below); the outputs are the
repository specs the extension would generate and the hub's BUILD file.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:extensions.bzl", "resolve_pub_packages")
load("//dart/pub/private:pub_emit.bzl", "pub_repo_specs")
load("//dart/pub/private:pub_lock_hub.bzl", "pub_lock_hub_content")
load("//dart/pub/private:pub_lock_package.bzl", "archive_fetch_error")
load("//dart/pub/private:pub_sources.bzl", "path_package_dir", "path_package_label")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

_LOCK = Label("//app:pubspec.lock")

def _hosted(version, sha):
    return {
        "dependency": "direct main",
        "description": {"name": "x", "sha256": sha, "url": "https://pub.dev"},
        "source": "hosted",
        "version": version,
    }

# As `dart pub get` writes them (the reader turns every scalar into a string).
def _path(path, relative = "True"):
    return {"dependency": "direct overridden", "description": {"path": path, "relative": relative}, "source": "path", "version": "1.4.0"}

_SDK = {"dependency": "direct main", "description": {"name": "flutter"}, "source": "sdk", "version": "0.0.0"}

def _tag(packages, name = "pub_deps", lock = _LOCK, isolated = False):
    return struct(name = name, lock = lock, packages = packages, on_version_conflict = "error", isolated = isolated)

def _path_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "app/forks/typed_data", path_package_dir("typed_data", _path("forks/typed_data"), _LOCK).dir)
    asserts.equals(env, "shared", path_package_dir("shared", _path("../shared"), _LOCK).dir, "relative to the lock's directory")
    asserts.equals(env, "", path_package_dir("root", _path(".."), _LOCK).dir, "the module root is a package directory too")
    asserts.equals(env, "app/pkgs/a", path_package_dir("a", _path("pkgs\\a"), _LOCK).dir, "a Windows-written lock")
    asserts.equals(env, "@@//app/pkgs/a:a", path_package_label("a", _LOCK, "app/pkgs/a"))

    outside = path_package_dir("outside_pkg", _path("../../outside_pkg"), _LOCK).error
    asserts.true(env, "outside_pkg" in outside and "outside the module" in outside and "move the package into it" in outside, outside)
    absolute = path_package_dir("abs", _path("/home/me/abs", relative = "False"), _LOCK).error
    asserts.true(env, "abs" in absolute and "absolute path \"/home/me/abs\"" in absolute, absolute)
    return unittest.end(env)

def _plans(names, deps = {}):
    return {
        name: {"deps": deps.get(name, []), "sdk": "^3.0.0", "archive_url": "https://pub.dev/api/archives/%s.tar.gz" % name}
        for name in names
    }

def _override_by_path_test_impl(ctx):
    """A `dependency_overrides` path fork of a hosted package's dependency."""
    env = unittest.begin(ctx)
    resolution = resolve_pub_packages([], [_tag({
        "crypto": _hosted("3.0.7", "1" * 64),
        "typed_data": _path("forks/typed_data"),
        "flutter": _SDK,
    })])
    asserts.equals(env, None, resolution.error)
    asserts.equals(env, ["crypto"], sorted(resolution.resolved.keys()), "only the hosted entry is fetched")
    specs = pub_repo_specs(resolution, [_plans(["crypto"], {"crypto": ["typed_data", "flutter"]})], {})
    asserts.equals(env, ["dart_pub__crypto", "pub_deps"], sorted(specs.keys()), "no repository for the path or the sdk package")
    asserts.equals(
        env,
        ["@@//app/forks/typed_data:typed_data"],
        specs["dart_pub__crypto"].attrs["deps"],
        "the hosted package depends on the module's own target for the fork; the SDK edge is dropped",
    )
    hub = specs["pub_deps"].attrs
    asserts.equals(env, ["crypto", "flutter", "typed_data"], hub["packages"])
    asserts.equals(env, {"typed_data": "@@//app/forks/typed_data:typed_data"}, hub["local_targets"])
    asserts.equals(env, ["flutter"], hub["unavailable"].keys())
    asserts.true(env, "flutter.pub" in hub["unavailable"]["flutter"], hub["unavailable"]["flutter"])
    return unittest.end(env)

def _hub_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = pub_lock_hub_content(
        ["crypto", "flutter", "typed_data"],
        [],
        "dart_pub",
        local_targets = {"typed_data": "@@//forks/typed_data:typed_data"},
        unavailable = {"flutter": "comes from the \"flutter\" SDK"},
    )
    asserts.true(env, content.startswith('load("@@'), content)
    asserts.true(env, 'actual = "@dart_pub__crypto//:crypto"' in content, content)
    asserts.true(env, 'actual = "@@//forks/typed_data:typed_data"' in content, content)
    asserts.true(env, 'pub_unavailable_package(\n    name = "flutter",\n    message = "comes from the \\"flutter\\" SDK",' in content, content)
    plain = pub_lock_hub_content(["crypto"], [], "dart_pub")
    asserts.false(env, "load(" in plain, "a hub with nothing unavailable loads nothing")
    return unittest.end(env)

def _errors_test_impl(ctx):
    env = unittest.begin(ctx)
    unknown = resolve_pub_packages([], [_tag({"odd": {"description": {}, "source": "svn", "version": "1.0.0"}})]).error
    asserts.true(env, unknown != None and "\"odd\"" in unknown and "\"svn\"" in unknown and "app:pubspec.lock" in unknown, unknown)

    outside = resolve_pub_packages([], [_tag({"far": _path("../../far")})]).error
    asserts.true(env, outside != None and "\"far\"" in outside and "outside the module" in outside, outside)

    other = Label("//other:pubspec.lock")
    clash = resolve_pub_packages([], [
        _tag({"typed_data": _path("forks/typed_data")}),
        _tag({"typed_data": _hosted("1.4.0", "2" * 64)}, name = "other", lock = other),
    ]).error
    asserts.true(env, clash != None and "a path package at @@//app/forks/typed_data:typed_data" in clash and "a hosted package" in clash, clash)

    two_dirs = resolve_pub_packages([], [
        _tag({"shared": _path("../shared")}),
        _tag({"shared": _path("shared")}, name = "other", lock = other),
    ]).error
    asserts.true(env, two_dirs != None and "@@//shared:shared" in two_dirs and "@@//other/shared:shared" in two_dirs, two_dirs)

    isolated = resolve_pub_packages([], [
        _tag({"shared": _path("../shared")}),
        _tag({"shared": _path("shared")}, name = "tool", lock = other, isolated = True),
    ])
    asserts.equals(env, None, isolated.error, "an isolated hub keeps its own path packages")
    return unittest.end(env)

def _archive_error_test_impl(ctx):
    env = unittest.begin(ctx)
    msg = archive_fetch_error("t38_secret", "1.0.0", "https://pub.example.com:8443/repo/api/archives/t38_secret-1.0.0.tar.gz", "https://pub.example.com:8443/repo/api/packages/t38_secret")
    asserts.true(env, "\"t38_secret\" 1.0.0" in msg, msg)
    asserts.true(env, "listing https://pub.example.com:8443/repo/api/packages/t38_secret" in msg, msg)
    asserts.true(env, "--credential_helper=pub.example.com=<helper>" in msg, msg)
    asserts.true(env, "`dart pub get`" in msg, msg)
    return unittest.end(env)

_path_dir_test = unittest.make(_path_dir_test_impl)
_override_by_path_test = unittest.make(_override_by_path_test_impl)
_hub_content_test = unittest.make(_hub_content_test_impl)
_errors_test = unittest.make(_errors_test_impl)
_archive_error_test = unittest.make(_archive_error_test_impl)

def pub_sources_test_suite(name):
    small_unittest_suite(
        name,
        _path_dir_test,
        _override_by_path_test,
        _hub_content_test,
        _errors_test,
        _archive_error_test,
    )
