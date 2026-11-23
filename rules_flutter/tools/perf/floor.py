#!/usr/bin/env python3
"""Toolchain floor chains for the mobile edit flows of the perf bench.

The replay floor (``sol.py``) re-runs the tool binaries Bazel ran, so it
contains whatever the rules decided to run. The toolchain floor is written
by hand against the SDK and platform tools directly, the way a person with
a resident compiler would do the same edit:

- debug edit (iOS simulator debug, Android debug): a resident
  ``frontend_server`` in incremental mode compiles the app once untimed,
  then recompiles after the body edit; the kernel blob is replaced inside
  the already built package in place; then the least re-signing the
  platform accepts (iOS: seal the changed bundle only, the unchanged
  frameworks keep their signatures; Android: re-sign once, no recompression
  and no realignment of unchanged entries). The timed cost is the
  recompile, the replace and the re-sign.
- release edit (iOS device release, Android release): the AOT kernel
  compile, one ``gen_snapshot``, the snapshot replaced inside the existing
  package, then the same minimum re-sign. Nothing else is timed.

Every tool path comes from the roots the bench workspace resolves (the
build's external repositories and the platform tool locations), never from
a host install; an unfindable tool is named in the error. This module only
builds the chain (pure data); ``floor_run.py`` executes it and
``floor_check.py`` checks the replaced package.
"""

import dataclasses
import json
import os
import sys

APP_SCHEME = "org-dartlang-app"
FLOOR_CONFIGS = ("sim_debug", "device_release", "android_debug",
                 "android_release")
_DEBUG_PASS = "floorpass"


class FloorError(RuntimeError):
    """The floor cannot run or its package failed the check."""


class MissingToolError(FloorError):
    """A tool the chain needs is not under any resolved root."""


class FloorUnavailableError(MissingToolError):
    """The build wrote no package config a debug floor can compile."""


@dataclasses.dataclass(frozen=True)
class FloorSpec:
    """What one floor chain works on.

    platform is ``ios`` or ``android``, mode ``debug`` or ``release``.
    package is the built ``.app``/``App.framework`` directory or the APK
    (a copy in scratch, never Bazel's output); entry is the root library
    ``org-dartlang-app:///`` URI, packages the ``<name>.package_config.json``
    the rules write, roots the directories mounted under that scheme (first
    wins), scratch a writable directory.
    """

    platform: str
    mode: str
    package: str
    entry: str
    packages: str
    scratch: str
    roots: tuple = ()


@dataclasses.dataclass(frozen=True)
class Step:
    """One chain step.

    kind is ``exec`` (a tool run to completion), ``frontend`` (the
    resident incremental compile: ``compile`` untimed, ``recompile``
    timed) or ``replace`` (the in-place payload replacement, ``call``
    names which one). timed steps add to the floor number.
    """

    name: str
    kind: str
    argv: tuple = ()
    timed: bool = True
    detail: tuple = ()


def _walk_files(root):
    """Yield every file path under ``root``, entering symlinked directories.

    A directory whose real path is already on the current path (a symlink
    loop) is not entered again; a dangling symlink or an unreadable
    directory is skipped.
    """
    stack = [(root, (os.path.realpath(root),))]
    while stack:
        top, ancestors = stack.pop()
        try:
            with os.scandir(top) as entries:
                listing = sorted(entries, key=lambda entry: entry.name)
        except OSError:
            continue
        for entry in listing:
            if entry.is_dir():
                real = os.path.realpath(entry.path)
                if real not in ancestors:
                    stack.append((entry.path, ancestors + (real,)))
            elif entry.is_file():
                yield entry.path


def _is_real_tool(path):
    """False for a test fixture: under a ``fake_sdk`` directory or empty."""
    if "fake_sdk" in path.split(os.sep):
        return False
    return os.path.getsize(path) > 0


def _host_dir():
    """The engine's per-host directory of the build machine."""
    return "darwin-x64" if sys.platform == "darwin" else "linux-x64"


DART_SDK_REPO = "ai_rules_dart++dart+dart_"
_ENGINE_PAIRED = ("dartaotruntime", "frontend_server_aot.dart.snapshot")


def _is_dart_sdk_path(relative):
    """True for a file of the standalone Dart SDK repository.

    ``relative`` is the path below the search root it was found under, so
    where the root lives never matters. That is a component starting
    ``ai_rules_dart++dart+dart_``, or a ``dart-sdk`` directory with no
    Flutter engine repository (a component naming ``flutter`` or
    ``engine``) above it, inside the root.
    """
    parts = relative.split(os.sep)
    if any(part.startswith(DART_SDK_REPO) for part in parts):
        return True
    if "dart-sdk" not in parts:
        return False
    above = parts[:parts.index("dart-sdk")]
    return not any("flutter" in part.lower() or "engine" in part.lower()
                   for part in above)


def _engine_first(name, found):
    """Candidates without the Dart SDK repository's, when any remain.

    ``found`` holds (root, path) pairs. The compiler snapshot and
    ``dartaotruntime`` must match the Flutter engine's
    ``platform_strong.dill``; the Dart SDK's own would not.
    """
    if name.rsplit("/", 1)[-1] not in _ENGINE_PAIRED:
        return found
    kept = [pair for pair in found
            if not _is_dart_sdk_path(os.path.relpath(pair[1], pair[0]))]
    return kept or found


def find_tool(name, roots, hint=None):
    """Path of the tool whose path ends with ``name`` under the roots.

    ``name`` may be a path suffix (``flutter_patched_sdk/platform_strong.dill``).
    Symlinked directories are searched too. A ``hint`` substring prefers
    matching paths (a tuple of hints: the first that matches). Files under
    ``fake_sdk`` and empty files never match. ``dartaotruntime`` and the
    frontend snapshot of the Dart SDK repository lose to the Flutter
    engine's. Raises MissingToolError naming the tool and the roots
    searched.
    """
    suffix = os.sep + name
    found = [(root, path) for root in roots for path in _walk_files(root)
             if path.endswith(suffix) and _is_real_tool(path)]
    found = [path for _, path in _engine_first(name, found)]
    for one in ((hint,) if isinstance(hint, str) else hint or ()):
        preferred = [path for path in found if one in path]
        if preferred:
            found = preferred
            break
    if not found:
        raise MissingToolError("floor tool %r not found under %s"
                               % (name, ", ".join(roots) or "(no roots)"))
    return sorted(found)[0]


def find_package_config(roots, name):
    """Path of the ``<name>.package_config.json`` the rules write.

    Only a file named exactly that matches; a bare ``package_config.json``
    is never produced by the rules. Symlinked directories are searched too.
    Raises MissingToolError naming the file and the roots searched.
    """
    wanted = os.sep + name + ".package_config.json"
    found = [path for root in roots for path in _walk_files(root)
             if path.endswith(wanted)]
    if not found:
        raise MissingToolError("floor package config %r not found under %s"
                               % (wanted[1:], ", ".join(roots) or "(no roots)"))
    return sorted(found)[0]


def _find_named(roots, filename):
    """Sorted paths of files named exactly ``filename`` under the roots."""
    wanted = os.sep + filename
    return sorted(path for root in roots for path in _walk_files(root)
                  if path.endswith(wanted))


def find_debug_package_config(roots, name):
    """(package config, dev config or None) of a debug app's floor.

    The whole-program ``<name>.package_config.json`` wins. A modular
    debug app does not write it, so the ``<name>.dev_package_config.json``
    of the dev loop is used with its ``<name>_dev_config.json`` (the
    filesystem roots). Raises FloorUnavailableError naming both package
    config files and the roots searched when neither exists, and
    MissingToolError naming the dev config when only the dev package
    config does.
    """
    whole = _find_named(roots, name + ".package_config.json")
    if whole:
        return whole[0], None
    dev = _find_named(roots, name + ".dev_package_config.json")
    searched = ", ".join(roots) or "(no roots)"
    if not dev:
        raise FloorUnavailableError(
            "floor unavailable: neither %r nor %r found under %s"
            % (name + ".package_config.json",
               name + ".dev_package_config.json", searched))
    config = _find_named(roots, name + "_dev_config.json")
    if not config:
        raise MissingToolError("floor dev config %r not found under %s"
                               % (name + "_dev_config.json", searched))
    return dev[0], config[0]


def dev_filesystem_roots(dev_config, execroot):
    """Absolute ``filesystemRoots`` of a ``<name>_dev_config.json``.

    The entries are exec-root-relative (``""`` is the exec root itself).
    Raises FloorError naming the file when it cannot be read, is not a
    JSON object or lacks a ``filesystemRoots`` list of strings.
    """
    try:
        with open(dev_config, encoding="utf-8") as handle:
            roots = json.load(handle).get("filesystemRoots")
    except (OSError, ValueError, AttributeError) as exc:
        raise FloorError("floor dev config %r unreadable: %s"
                         % (dev_config, exc)) from exc
    if (not isinstance(roots, list)
            or not all(isinstance(one, str) for one in roots)):
        raise FloorError("floor dev config %r has no filesystemRoots list"
                         % dev_config)
    return [os.path.normpath(os.path.join(execroot, one)) for one in roots]


def _tool_names(spec):
    """(name, hint) pairs the chain of this spec needs, by tool key."""
    sdk = ("flutter_patched_sdk_product" if spec.mode == "release"
           else "flutter_patched_sdk")
    names = {"dartaotruntime": ("dartaotruntime", None),
             "frontend": ("frontend_server_aot.dart.snapshot", None),
             "platform": (sdk + "/platform_strong.dill", None)}
    if spec.mode == "release":
        arch = "ios" if spec.platform == "ios" else "android-arm64"
        release = arch + "-release"
        hint = ((release + os.sep + _host_dir(), release)
                if spec.platform == "android" else release)
        names["gen_snapshot"] = ("gen_snapshot", hint)
    if spec.platform == "ios":
        names["codesign"] = ("codesign", None)
    else:
        names["apksigner"] = ("apksigner", None)
        names["zipalign"] = ("zipalign", None)
        names["keytool"] = ("keytool", None)
    return names


def resolve_tools(spec, roots):
    """{tool key: path} for the spec; the first missing tool raises."""
    return {key: find_tool(name, roots, hint)
            for key, (name, hint) in _tool_names(spec).items()}


def frontend_argv(spec, tools, output, incremental):
    """The frontend_server command line (debug: resident incremental)."""
    sdk_root = os.path.dirname(tools["platform"]) + os.sep
    argv = [tools["dartaotruntime"], tools["frontend"],
            "--sdk-root", sdk_root, "--platform", tools["platform"],
            "--target=flutter", "--packages", spec.packages,
            "--output-dill", output]
    for root in spec.roots:
        argv += ["--filesystem-root", root]
    argv += ["--filesystem-scheme", APP_SCHEME]
    if incremental:
        argv += ["--incremental", "--track-widget-creation",
                 "--enable-asserts"]
    else:
        argv += ["--aot", "--tfa", "-Ddart.vm.product=true", spec.entry]
    return tuple(argv)


def sign_steps(spec, tools):
    """The minimum re-sign steps for the platform (timed).

    iOS seals the changed bundle only: no ``--deep``, so nested frameworks
    keep their signatures. Android signs the package once with the v2
    scheme only: no v1 entries are added, no entry is recompressed or
    realigned.
    """
    if spec.platform == "ios":
        argv = (tools["codesign"], "--force", "--sign", "-",
                "--preserve-metadata=identifier,entitlements,flags",
                spec.package)
        return [Step("resign", "exec", argv)]
    keystore = os.path.join(spec.scratch, "floor.keystore")
    pass_arg = "pass:" + _DEBUG_PASS
    keygen = (tools["keytool"], "-genkeypair", "-keystore", keystore,
              "-storepass", _DEBUG_PASS, "-keypass", _DEBUG_PASS,
              "-alias", "floor", "-keyalg", "RSA", "-keysize", "2048",
              "-validity", "3650", "-dname", "CN=floor")
    sign = (tools["apksigner"], "sign", "--ks", keystore,
            "--ks-pass", pass_arg, "--key-pass", pass_arg,
            "--v1-signing-enabled", "false",
            "--v2-signing-enabled", "true", spec.package)
    return [Step("keygen", "exec", keygen, timed=False),
            Step("resign", "exec", sign)]


def payload_name(spec):
    """Package entry/file the replace step swaps (None: found at run time)."""
    if spec.mode == "debug":
        return "kernel_blob.bin"
    return "libapp.so" if spec.platform == "android" else "App"


def build_chain(spec, tools):
    """Ordered Steps of the floor chain for one mobile edit flow."""
    out = os.path.join(spec.scratch, "app.dill")
    if spec.mode == "debug":
        argv = frontend_argv(spec, tools, out, incremental=True)
        front = [Step("frontend-compile", "frontend", argv, timed=False,
                      detail=("compile", spec.entry)),
                 Step("frontend-recompile", "frontend", argv,
                      detail=("recompile", spec.entry))]
        source = out
    else:
        argv = frontend_argv(spec, tools, out, incremental=False)
        snapshot = os.path.join(spec.scratch, payload_name(spec))
        front = [Step("aot-kernel", "exec", argv),
                 Step("gen_snapshot", "exec",
                      gen_snapshot_argv(spec, tools, out, snapshot))]
        source = snapshot
    replace = Step("replace", "replace", (), detail=(
        source, payload_name(spec)))
    sign = sign_steps(spec, tools)
    return [step for step in sign if not step.timed] + front + [
        replace] + [step for step in sign if step.timed]


def gen_snapshot_argv(spec, tools, kernel, snapshot):
    """The single gen_snapshot invocation of a release chain."""
    if spec.platform == "ios":
        kind = ("--snapshot_kind=app-aot-macho-dylib",
                "--macho=" + snapshot)
    else:
        kind = ("--snapshot_kind=app-aot-elf", "--elf=" + snapshot)
    return (tools["gen_snapshot"], "--deterministic") + kind + (kernel,)
