"""Shared utilities for Dart rules."""

load("//dart:providers.bzl", "DartCompileInfo", "DartInfo", "DartPackageMetadataInfo")
load("//dart/private:dart_info.bzl", "derived_package_info")
load("//dart/private:source_set.bzl", "package_for_index", "package_index")

visibility(["//dart/..."])

# Private attribute for detecting Windows at analysis time (for .exe extension).
WINDOWS_CONSTRAINT_ATTR = {
    "_windows_constraint": attr.label(
        doc = "Platform constraint value probed at analysis time to detect Windows, for the `.exe` output suffix. Defaults to `@platforms//os:windows`.",
        default = "@platforms//os:windows",
    ),
}

# Private attributes for resolving the Dart code-asset ABI string
# (`<os>_<arch>`, e.g. `macos_arm64`) from the target platform at analysis
# time. `DartSdkInfo.target_os/target_arch` are empty for native/host
# toolchains (the only ones a test runs under), so we probe constraints
# directly — the idiomatic pattern in this repo (see WINDOWS_CONSTRAINT_ATTR).
#
# Attrs are named after the DART arch, not the Bazel constraint value: Dart's
# `arm64` is Bazel's `aarch64`, its `x64` is `x86_64`, and its `arm` is `armv7`.
# The set covers every CPU rules_dart registers a toolchain for, so a user who
# brings their own cc toolchain for one of them is not blocked here.
DART_ABI_CONSTRAINT_ATTRS = {
    "_os_macos": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI OS string when the SDK toolchain leaves it empty. Defaults to `@platforms//os:macos`.",
        default = "@platforms//os:macos",
    ),
    "_os_linux": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI OS string when the SDK toolchain leaves it empty. Defaults to `@platforms//os:linux`.",
        default = "@platforms//os:linux",
    ),
    "_os_windows": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI OS string when the SDK toolchain leaves it empty. Defaults to `@platforms//os:windows`.",
        default = "@platforms//os:windows",
    ),
    "_cpu_arm64": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI arch string when the SDK toolchain leaves it empty. Defaults to `@platforms//cpu:aarch64`.",
        default = "@platforms//cpu:aarch64",
    ),
    "_cpu_x64": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI arch string when the SDK toolchain leaves it empty. Defaults to `@platforms//cpu:x86_64`.",
        default = "@platforms//cpu:x86_64",
    ),
    "_cpu_riscv64": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI arch string when the SDK toolchain leaves it empty. Defaults to `@platforms//cpu:riscv64`.",
        default = "@platforms//cpu:riscv64",
    ),
    "_cpu_arm": attr.label(
        doc = "Platform constraint probed at analysis time to derive the code-asset ABI arch string when the SDK toolchain leaves it empty. Defaults to `@platforms//cpu:armv7`.",
        default = "@platforms//cpu:armv7",
    ),
}

def runfiles_path(f, workspace_name):
    """Convert a File to its runfiles-relative path.

    Args:
        f: The `File` whose runfiles path is wanted; its `short_path` decides the result.
        workspace_name: The workspace name (ctx.workspace_name).

    Returns:
        The runfiles-relative path string.
    """
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def create_test_executable(ctx, tool, env, env_inherit = []):
    """Create a test executable by symlinking a pre-compiled tool binary.

    Handles .exe extension on Windows. Returns the executable file and a
    RunEnvironmentInfo provider for passing configuration via env vars.

    Args:
        ctx: The rule context.
        tool: The pre-compiled tool target (from a cfg="exec" attr).
        env: Dict of environment variable names to values for RunEnvironmentInfo.
        env_inherit: Names of variables passed through from the environment
            the test is started in.

    Returns:
        Tuple of (executable File, RunEnvironmentInfo provider, tool runfiles).
    """
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)

    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    env_info = RunEnvironmentInfo(environment = env, inherited_environment = env_inherit)
    tool_runfiles = tool[DefaultInfo].default_runfiles

    return executable, env_info, tool_runfiles

def package_native_assets(pkg):
    """A `DartPackageInfo`'s native assets, tolerating older producers.

    `native_assets` is optional in the same sense `language_version` is: a
    record built by a producer that predates the field, or by
    `//dart/tests/no_lv_fixture`, omits it and simply contributes none.

    Args:
      pkg: The `DartPackageInfo` whose native assets to read.

    Returns:
      Tuple of Files; empty when the field is absent.
    """
    return getattr(pkg, "native_assets", ())

def package_link_hook(pkg):
    """A `DartPackageInfo`'s `hook/link.dart`, tolerating older producers.

    Args:
      pkg: The `DartPackageInfo` whose link hook to read.

    Returns:
      The hook File, or `None` when the package has none or the record
      predates the field.
    """
    return getattr(pkg, "link_hook", None)

def collect_native_assets(deps):
    """Merges `DartInfo.transitive_native_assets` across deps.

    Args:
      deps: List of targets providing `DartInfo`.

    Returns:
      `depset[File]`: every transitive build hook output directory, and each
      `dart_code_asset`'s `.assets.json` and library.
    """
    return depset(transitive = [
        dep[DartInfo].transitive_native_assets
        for dep in deps
        if hasattr(dep[DartInfo], "transitive_native_assets")
    ])

def own_package_record(info):
    """Returns the `DartPackageInfo` for the package a `DartInfo` itself owns.

    A `DartInfo` names its own package by `package_name`/`lib_root` but does
    not carry that package's record: the record sits in `transitive_packages`
    beside every dependency's. Both fields are the key, not the name alone —
    one `package_name` legitimately maps to several `lib_root`s (a package
    split across targets; two pub hubs each supplying `meta`), so matching on
    the name would sometimes return a dependency's record instead of this
    target's, and with it a dependency's language version.

    Args:
      info: The `DartInfo` whose own package record to find.

    Returns:
      The matching `DartPackageInfo`, or `None` when the target contributes no
      package of its own (`dart_info_no_package`) or no record matches.
    """
    if not info.package_name:
        return None
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == info.package_name and pkg.lib_root == info.lib_root:
            return pkg
    return None

def owned_package_records(info):
    """Returns every `DartPackageInfo` record the `DartInfo` itself owns.

    Most targets own exactly one package, and this returns it in a list.
    A merged multi-package target (one `dart_library` over a pub dependency
    cycle) owns one record per member package, and a facade owns none.

    Reads `DartInfo.owned_packages`, which every constructor in
    `dart_info.bzl` sets. A `DartInfo` built by hand — or by a producer from
    before the field existed — carries none, so those fall back to the
    single record `own_package_record` matches, or to empty when the target
    contributes no package at all.

    Args:
      info: The `DartInfo` whose owned package records to list.

    Returns:
      The owned `DartPackageInfo` records, in order.
    """
    owned = getattr(info, "owned_packages", None)
    if owned != None:
        return list(owned)
    record = own_package_record(info)
    return [record] if record != None else []

def collect_packages(deps):
    """Collect unique DartPackageInfo providers from transitive deps.

    Flattens the merged transitive depset exactly once (package metadata is
    inspected per-entry for dedup, so a flatten is unavoidable here — but it
    is bounded by the package count, not the source-file count).

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    return merge_package_records(
        depset(transitive = [dep[DartInfo].transitive_packages for dep in deps]).to_list(),
    )

_VERSION_REMEDY = """
Each package listed just above was resolved to different versions by two
package sources. Typically two pub hubs — rules_flutter's `flutter.pub()` and
rules_dart's `pub.from_lock()` each generating a spoke for the same package —
whose lock files have drifted apart. Only one record per package can win, and
dependency order would decide which, so the build would compile against
whichever came first regardless of what the other's lock pins.

Reconcile the lock files feeding the two hubs so both pin one version of each,
then re-run `dart pub get` / `flutter pub get` in each workspace. Every package
that disagrees is listed, so one reconciliation settles all of them.

rules_dart does not support multiple versions of a package.
"""

_LANGUAGE_VERSION_REMEDY = """
Each package listed just above has records stating different
`language_version`s, so the Dart semantics its sources compile under would be
decided by dependency order. Set `language_version` consistently on every
`dart_library` contributing to the package, or point each at one
`dart_package_metadata`.
"""

# The attribute every rule that builds part of a Dart package gains, pointing at
# the one `dart_package_metadata` that declares the package's name and language version.
PACKAGE_IDENTITY_ATTRS = {
    "package": attr.label(
        providers = [DartPackageMetadataInfo],
        doc = "A `dart_package_metadata` declaring this Dart package's `package_name` and `language_version`. Mutually exclusive with the inline `package_name` / `language_version` attributes: set `package` to state those facts once for every rule building this package, or set them inline, but never both. Referencing a target is what lets rules in *different* BUILD files share one declaration, which a macro cannot do.",
    ),
}

def resolve_package_identity(ctx):
    """Resolves a rule's Dart package identity from `package` or inline attrs.

    Two ways to state one thing would be two ways for it to be wrong, so this
    refuses the overlap outright rather than defining a precedence: a rule that
    sets `package` and an inline attribute fails, whether or not the two agree.
    Agreement today is not agreement after the next edit, and a silently ignored
    attribute is the failure this whole mechanism exists to remove.

    Tolerant about which attributes the calling rule actually declares: a rule
    with a `language_version` and no `package_name` needs no change here.

    Args:
      ctx: The rule context. Must declare `package`; may declare
        `package_name` and/or `language_version`.

    Returns:
      `struct(package_name, language_version)`, either of which may be "".
    """
    inline_name = getattr(ctx.attr, "package_name", "")
    inline_language_version = getattr(ctx.attr, "language_version", "")
    declaration = getattr(ctx.attr, "package", None)

    if declaration == None:
        return struct(
            package_name = inline_name,
            language_version = inline_language_version,
        )

    also_set = []
    if inline_name:
        also_set.append("package_name")
    if inline_language_version:
        also_set.append("language_version")
    if also_set:
        fail(("%s: sets `package` and also %s. `package = \"%s\"` already " +
              "states %s for this package; drop the inline %s, or drop " +
              "`package` and state everything inline.") % (
            ctx.label,
            " and ".join(["`%s`" % a for a in also_set]),
            declaration.label,
            "them" if len(also_set) > 1 else "it",
            "attributes" if len(also_set) > 1 else "attribute",
        ))

    declared = declaration[DartPackageMetadataInfo]
    return struct(
        package_name = declared.package_name,
        language_version = declared.language_version,
    )

def package_agreement_error(merged):
    """Reports every duplicate record that states facts its twin contradicts.

    Two records for one `package_name` are normal — see `merge_package_records`
    for why — but they are supposed to describe the *same* package. When they
    disagree, `merge_package_records` keeps the first and discards the second,
    which silently substitutes one version's entire source tree for the other's.
    A skewed pair of lock files reproduces exactly that: the build succeeds, no
    diagnostic is emitted, and a package compiles against sources its own lock
    does not pin.

    Only two *known* values can disagree. A record whose producer does not emit
    the field carries "" — every `DartPackageInfo` built by a rule set that
    predates it, and every hand-written `dart_library`, which has no version to
    state. Treating "" as a disagreement would fail every dual-hub build
    including the agreeing ones; treating it as "knows less" is what lets the
    field be adopted one producer at a time.

    Every disagreement is reported at once, across both fields, because the
    cause is almost always one skew producing many of them: a pair of lock
    files that drifted apart disagrees about every package whose version moved
    between them. Naming only the first turns one reconciliation into a round
    of fix-one, re-analyse, see-the-next per package, and `--keep_going` buys
    nothing since every failing target reports that same first name. The full
    list costs nothing to produce — it is already accumulated before the first
    is found.

    Pure, and separate from `merge_package_records`, for the same reason
    `check_code_asset_ownership` is separate from `dart_info`: the caller owns
    the `fail`, so the rule can be tested by calling it.

    Args:
      merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
      An error message string naming every disagreement, or `None` when every
      duplicate agrees.
    """
    blocks = []
    for field, label, remedy in (
        ("version", "versions", _VERSION_REMEDY),
        ("language_version", "language versions", _LANGUAGE_VERSION_REMEDY),
    ):
        # value -> lib_root of the first record stating it, per package name.
        stated = {}
        for pkg in merged:
            value = getattr(pkg, field, "")
            if not value:
                continue
            seen = stated.setdefault(pkg.package_name, {})
            if value not in seen:
                seen[value] = pkg.lib_root

        reported = []
        for package_name in sorted(stated.keys()):
            seen = stated[package_name]
            if len(seen) < 2:
                continue
            reported.append(
                "Package \"%s\" is supplied more than once with different %s:\n" % (package_name, label) +
                "".join([
                    "  - %s (%s)\n" % (value, seen[value])
                    for value in sorted(seen.keys())
                ]),
            )

        # One remedy per field, after that field's packages: the fix is the
        # same for all of them, and repeating the paragraph per package is what
        # makes a wide report unreadable.
        if reported:
            blocks.append("".join(reported) + remedy)

    if not blocks:
        return None
    return "\n".join(blocks)

def merge_package_records(merged):
    """Dedups package records by name, unioning their native assets.

    One `package_name` can legitimately appear in several records:

      * a package split across `dart_library` targets, whose records share a
        `lib_root`, so the compile resolves all its files together (see
        `executable_inputs`); and
      * a package supplied independently by two pub hubs, e.g. rules_flutter's
        `flutter.pub()` and rules_dart's `pub.from_lock()` both generating a
        spoke for `ffi`. These can carry different `lib_root`s.

    So the first record wins for source resolution, as it always has, and the
    result names each package at one `lib_root`. Native assets are the
    exception: dropping a later record's would silently lose a native library,
    and the failure would surface at runtime as an unresolved `@Native`
    symbol. Union them instead; the manifest step fails if two assets claim
    one id, which is the case the Dart VM cannot resolve either.

    First-record-wins is only safe once the records are known to agree, so this
    calls `package_agreement_error` first and fails when two of them state
    different `version`s or `language_version`s.

    Split out from `collect_packages` because the dedup and union rules are a
    pure function of the record list, which makes them directly testable
    without synthesising `DartInfo`-bearing targets. The agreement check keeps
    that property by living in its own function and returning its message.

    Args:
        merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    err = package_agreement_error(merged)
    if err != None:
        fail(err)

    packages = []
    index_by_name = {}
    for pkg in merged:
        index = index_by_name.get(pkg.package_name)
        if index == None:
            index_by_name[pkg.package_name] = len(packages)
            packages.append(pkg)
        else:
            kept = packages[index]
            adopt_hook = package_link_hook(pkg) != None and package_link_hook(kept) == None
            extra = [f for f in package_native_assets(pkg) if f not in package_native_assets(kept)]
            if not extra and not adopt_hook:
                continue

            # Only the assets and a missing link hook merge; every other field
            # stays the kept record's. The link hook is adopted for the same
            # reason the assets are: a package split across targets may carry
            # its `hook/link.dart` on any one of them, and dropping it would
            # silently skip the hook.
            packages[index] = derived_package_info(
                kept,
                native_assets = package_native_assets(kept) + tuple(extra),
                link_hook = package_link_hook(pkg) if adopt_hook else None,
            )
    return packages

def noop_test_executable(ctx, tool):
    """Symlinks the do-nothing binary as a test rule's executable.

    A test whose verdict is decided in a build action — the `dart_analyze`
    aspect's, in this repository's own tests — has nothing left for the test
    binary to check. It must still *be* a test, so it hands Bazel a
    pass-through executable.

    Args:
      ctx: The rule context (must carry `WINDOWS_CONSTRAINT_ATTR`).
      tool: The `//dart/private/tools:noop` target.

    Returns:
      `struct(executable, runfiles)` — the declared symlink and the tool's own
      runfiles, for the caller to merge with whatever stamp it produced.
    """
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    return struct(
        executable = executable,
        runfiles = tool[DefaultInfo].default_runfiles,
    )

# Seconds a snapshot training waits for its keyed training lock before the
# action fails (or falls back where allowed). The default of
# `//dart:jit_snapshot_lock_timeout`: both snapshot actions pass
# `--lock-timeout=` only when set differently, so the action key follows a
# non-default deadline. The tool's own default matches; keep the two equal.
JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT = 300

# Mask keeping digests in 64 bits (Starlark integers are arbitrary precision).
_MASK64 = 18446744073709551615

def _digest64(seed, s):
    """Digests a string deterministically into 64 bits.

    FNV-1a over its characters, finished with murmur3's 64-bit finalizer for
    avalanche.

    Each character contributes its single-character `hash()` code. For one
    code unit the Java `String.hashCode` is the code unit itself, so this
    mixes a code-unit stream into a full 64 bits of state — not the
    linearly-related whole-string hashes two `hash()` calls produce (where the
    second half is derivable from the first, leaving about 32 bits). A pure
    function of its inputs (identical across machines, output bases and
    strategies): each key pairs a distinct seed with a distinct domain prefix,
    so the keys are independent of each other.
    """
    h = seed & _MASK64
    for i in range(len(s)):
        h = ((h ^ (hash(s[i]) & _MASK64)) * 1099511628211) & _MASK64
    h = (h ^ (h >> 33)) & _MASK64
    h = (h * 0xff51afd7ed558ccd) & _MASK64
    h = (h ^ (h >> 33)) & _MASK64
    h = (h * 0xc4ceb9fe1a85ec53) & _MASK64
    h = (h ^ (h >> 33)) & _MASK64
    return h

def _hex64(v):
    """Renders a 64-bit digest as 16 lowercase hex characters."""
    digits = "0123456789abcdef"
    key = ""
    for _i in range(16):
        key = digits[v % 16] + key
        v = v // 16
    return key

def jit_train_key(short_path):
    """The keyed-training key for a declared snapshot output.

    16 lowercase hex characters of a 64-bit digest of the output's
    root-relative path (`File.short_path`; see `_digest64`). The key depends
    only on that path, so it is identical across output bases, strategies and
    machines, and two different targets hold different keys (so their trainings
    run in parallel) while concurrent trainings of one output contend for one
    lock. See `app_jit_snapshot.dart`.

    Args:
        short_path: The declared output's root-relative path.

    Returns:
        The 16-character key both snapshot actions pass as `--train-key=`.
    """
    return _hex64(_digest64(0x9e3779b97f4a7c15, "rules_dart_jit_train:" + short_path))

def sdk_dartvm(dart_sdk_info):
    """Returns the SDK's `dartvm` executable File, or None if the SDK has none.

    The app-JIT training runs from a copy of `dart` and `dartvm`, and the
    compile and runtime file sets both carry `bin/dartvm*` (see
    `dart/repositories.bzl`), so the file is an action input already. A custom
    toolchain whose subsets omit `dartvm` gets it added back by the
    `dart_toolchain` implementation (see `dart/toolchain.bzl`), so the compile
    subset carries the file whenever the SDK layout has one: this lookup reads
    that subset only.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the toolchain.

    Returns:
      The `dartvm` File, or None for an SDK layout without one.
    """
    for f in dart_sdk_info.compile_files.to_list():
        if f.basename in ("dartvm", "dartvm.exe"):
            return f
    return None

def writable_home_env(dart, beside = None):
    """The environment an SDK build action sets so it never uses a shared home.

    The `dart` CLI and analysis server write state under the user's home
    directory (`.dart-tool`, `.dart`, `.dartServer`). Clearing `HOME` (and
    `USERPROFILE` / `LOCALAPPDATA` on Windows) in the action environment
    prevents any process from falling back to a shared host or package
    directory (`~`, `/tmp`, `beside.dirname`), while keeping `env` identical
    across every action of a mnemonic and configuration so persistent workers
    share a single worker key. Each runner creates its own private directory
    under the system temp directory at run time for the SDK subprocesses it
    spawns and removes it on exit.

    Args:
      dart: The SDK's `dart` File, whose basename identifies the platform.
      beside: Unused; retained for caller compatibility.

    Returns:
      A dict for `ctx.actions.run(env = ...)`.
    """
    _ = beside
    if dart.basename.endswith(".exe"):
        return {"USERPROFILE": "", "LOCALAPPDATA": ""}
    return {"HOME": ""}

def relative_path(from_dir, to_dir):
    """Compute the relative path from one directory to another.

    Both paths must be in the same coordinate system (e.g., both exec-root-relative).

    Args:
        from_dir: The starting directory path.
        to_dir: The target directory path.

    Returns:
        A relative path string from from_dir to to_dir.
    """
    from_parts = from_dir.split("/") if from_dir else []
    to_parts = to_dir.split("/") if to_dir else []

    # Find common prefix length
    common = 0
    for i in range(min(len(from_parts), len(to_parts))):
        if from_parts[i] != to_parts[i]:
            break
        common = i + 1

    ups = len(from_parts) - common
    remaining = to_parts[common:]
    parts = [".."] * ups + remaining
    return "/".join(parts) if parts else "."

def check_single_root_package(packages):
    """Checks that at most one package claims the empty (root) `lib_root`.

    Two or more empty-lib_root packages are ambiguous: the empty-prefix match
    would race to claim any `lib/`-prefixed source.

    Args:
        packages: List of DartPackageInfo providers.

    Returns:
        An error message string when more than one package has an empty
        `lib_root`, else `None`.
    """
    root_names = [pkg.package_name for pkg in packages if not pkg.lib_root]
    if len(root_names) > 1:
        return (
            "Multiple packages declare an empty `lib_root`: %s. Each " +
            "Bazel build graph can only attribute `lib/...` sources to " +
            "one root package."
        ) % ", ".join(root_names)
    return None

def package_exec_root(src, lib_root):
    """Returns the exec-root-relative directory that holds `src`'s package.

    `src.short_path` less the package's `lib_root` is the package-relative
    tail (`/lib/...`, or empty for an opaque package directory); stripping
    that tail off `src.path` leaves the directory the package sits in. For a
    file generated into an external repository that directory is under
    `bazel-out/`, not `external/`, which is how a caller can tell the two apart.

    Args:
        src: A File with `short_path` and `path`.
        lib_root: The owning package's `lib_root`.

    Returns:
        The exec-root-relative directory, without a trailing slash.
    """
    suffix = src.short_path[len(lib_root):]
    exec_root = src.path[:len(src.path) - len(suffix)]
    if exec_root.endswith("/"):
        exec_root = exec_root[:-1]
    return exec_root

def resolve_package_roots(packages, all_srcs):
    """Match packages to source files, returning exec-root-relative roots.

    Ownership is `package_for`'s and only `package_for`'s: a file resolves a
    package's root only if it is one the package could actually export — under
    `<lib_root>/lib/`, or the `lib_root` directory itself. Matching anything
    else under `lib_root` was the bug: a `dart_test` sitting in the same Bazel
    package as the library it tests (`packages/foo/BUILD.bazel` declaring both
    `dart_library(foo)` and its test, which is the ordinary pub layout) makes
    the rule declare its dependencies' assembled `.pkgsrcs` directories at
    `packages/foo/<test>.<dep>.pkgsrcs`. That path starts with `packages/foo/`,
    so `foo` claimed it and resolved its own root to
    `bazel-out/.../bin/packages/foo` — a directory with no `lib/` in it — and
    every `package:foo/…` import failed to read.

    Two or more packages with an empty `lib_root` are ambiguous — the
    empty-prefix match would race to claim any `lib/`-prefixed source.
    Fail loud if detected; callers should not be building transitive
    `DartInfo` graphs with colliding root assignments.

    Args:
        packages: List of DartPackageInfo providers.
        all_srcs: List of File objects from the transitive source closure.

    Returns:
        Dict mapping package_name to exec-root-relative package root path.
    """
    err = check_single_root_package(packages)
    if err:
        fail(err)

    by_name = {pkg.package_name: pkg for pkg in packages}
    roots = {}
    index = package_index(packages)
    for src in all_srcs:
        name = package_for_index(src.short_path, index)
        if name == None or name in roots:
            continue

        roots[name] = package_exec_root(src, by_name[name].lib_root)
    return roots

def generate_package_config(packages, all_srcs, config_file, roots = {}):
    """Generate package_config.json content using short_path-based lib_root.

    Resolves exec-root paths from source files, then computes relative
    rootUri from config_file's dirname to each package's exec-root location.

    Args:
        packages: List of DartPackageInfo providers.
        all_srcs: List of File objects from the transitive source closure.
        config_file: The output File for package_config.json (used for dirname).
        roots: Dict of package name to exec-root-relative root, for packages
            whose root no file in `all_srcs` reveals — an executable's own
            package with no `lib/` files (see `executable_inputs`). A root
            found from the files wins.

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    exec_roots = dict(roots)
    exec_roots.update(resolve_package_roots(packages, all_srcs))
    config_dir = config_file.dirname

    entries = []
    for pkg in packages:
        exec_root = exec_roots.get(pkg.package_name)
        if exec_root != None:
            root_uri = relative_path(config_dir, exec_root)
        elif not pkg.lib_root:
            # Root package with no sources found — fall back to depth-based
            root_uri = relative_path(config_dir, "")
        else:
            # Package contributes no .dart sources to the transitive closure.
            # Two legitimate cases hit this:
            #   1. asset/font-only pub deps (e.g. `cupertino_icons`) pulled
            #      into a Flutter app — assets ride through other providers,
            #      not `package:` URIs;
            #   2. an aggregate `dart_library(srcs = [])` façade that exists
            #      only to re-export its deps.
            # Either way no consumer needs a `rootUri` for this package. If
            # anything *does* import `package:<name>/…`, the Dart frontend
            # reports a localized URI-not-found at the import — clearer than
            # failing the whole package_config build here.
            continue
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

# The URI scheme every compile resolves its inputs through. The frontend maps it
# with `--filesystem-root` (see `gen_kernel_args`), so a file's URI is its
# repository-relative path and never the absolute sandbox path it was read from.
STABLE_SCHEME = "org-dartlang-root"
KERNEL_FILESYSTEM_SCHEME = STABLE_SCHEME

def kernel_uri(path):
    """Builds the `KERNEL_FILESYSTEM_SCHEME` URI of an exec-root-relative path.

    Args:
      path: The path of the file relative to the execution root.

    Returns:
      The URI string `org-dartlang-root:///<path>`.
    """
    return KERNEL_FILESYSTEM_SCHEME + ":///" + path

def stable_path(path):
    """Returns the path a stable URI names, for a `short_path` or an exec path.

    A file from another repository has the short path `../repo/x`, and lives at
    `external/repo/x` under the exec root, where the scheme's roots look.

    Args:
        path: A `short_path`, or an exec-root-relative path without the bin root.

    Returns:
        The path with a leading `../` replaced by `external/`.
    """
    if path.startswith("../"):
        return "external/" + path[3:]
    return path

def stable_entry_path(ctx, exec_path):
    """Returns the stable path of an entrypoint given by its exec path.

    The entrypoint may be a generated file, so its exec path begins with the
    bin root; that prefix is what the scheme's second root supplies, and is
    removed here.

    Args:
        ctx: The rule context, for its bin directory.
        exec_path: The entrypoint's exec-root-relative path.

    Returns:
        The path to append to `STABLE_SCHEME:///`.
    """
    prefix = ctx.bin_dir.path + "/"
    if exec_path.startswith(prefix):
        exec_path = exec_path[len(prefix):]
    return stable_path(exec_path)

def generate_stable_package_config(packages, all_srcs, roots = None, scheme = STABLE_SCHEME):
    """Generates a package_config.json whose roots are stable scheme URIs.

    `generate_package_config` gives each package an exec-root-relative
    `rootUri`, which `dart compile` turns into an absolute `file:` URI, so every
    compiled output embeds the sandbox it was built in. This variant names each
    package by its `lib_root` under `scheme`, which `gen_kernel_args`
    resolves against the exec root and the bin root. A colocated `.pkgsrcs`
    directory's `lib_root` is its own `short_path`, so it resolves the same way.

    Packages are kept under the same rule as `generate_package_config`: a
    package with no `.dart` source in `all_srcs` and no `roots` entry is an
    asset-only pub dependency, and no consumer needs its root.

    Args:
        packages: List of DartPackageInfo providers.
        all_srcs: List of File objects from the transitive source closure.
        roots: Dict of package name to exec-root-relative root for packages
            whose files no `lib/` file reveals (see `executable_inputs`).
            Only the keys are read: a package named here is kept.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    check_err = check_single_root_package(packages)
    if check_err:
        fail(check_err)

    index = package_index(packages)
    used = {name: True for name in (roots or {})}
    for f in all_srcs:
        name = package_for_index(f.short_path, index)
        if name != None:
            used[name] = True

    entries = []
    for pkg in packages:
        if pkg.package_name not in used and pkg.lib_root:
            continue
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{scheme}:///{root}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                scheme = scheme,
                root = stable_path(pkg.lib_root),
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def gen_kernel_args(ctx, tools, platform, package_config, scheme = STABLE_SCHEME, gen_kernel_snapshot = None):
    """Starts the argument list of a `gen_kernel` run whose URIs are stable.

    The two `--filesystem-root`s are relative to the action's working directory,
    the exec root. The first serves source files and the second the outputs of
    the bin root, so a stale generated file in `bazel-out` cannot shadow a
    declared source file at the same relative path. The caller appends the mode
    flags, `-o`, and the entrypoint as `<scheme>:///<stable_entry_path>`.

    Args:
        ctx: The rule context, for its bin directory.
        tools: The `find_sdk_kernel_tools` struct.
        platform: The platform dill File to compile against: the product one
            for an AOT kernel, the strong one otherwise.
        package_config: The `package_config.json` File, or None.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
        gen_kernel_snapshot: The snapshot File to run, for a compile whose
            defines need comma-splitting disabled (the toolchain's
            `patched_gen_kernel`). Defaults to `tools.gen_kernel_snapshot`.

    Returns:
        A `ctx.actions.args()` object beginning with the `gen_kernel` snapshot,
        which the caller runs with `dartaotruntime`.
    """
    args = ctx.actions.args()
    args.add(gen_kernel_snapshot if gen_kernel_snapshot != None else tools.gen_kernel_snapshot)
    args.add("--platform", platform)
    if package_config != None:
        args.add("--packages", package_config)
    args.add("--filesystem-scheme", scheme)
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    return args

def generate_package_config_content(packages, prefix):
    """Generate package_config.json content string (prefix-based).

    Simple version for staging-directory contexts where the relationship between
    the config file and package roots is known statically (e.g., dart_analyze
    where config is at .dart_tool/ and packages are at ../<lib_root>).

    Args:
        packages: List of DartPackageInfo providers.
        prefix: Path prefix to prepend to each package's lib_root for rootUri.

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    entries = []
    for pkg in packages:
        root_uri = prefix + "/" + pkg.lib_root if pkg.lib_root else prefix
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def collect_transitive_srcs(deps):
    """Collect all transitive source files from DartInfo deps.

    Returns a depset so consumers can feed action inputs / runfiles without
    flattening. Callers that genuinely inspect per-file paths (package
    lookup, package_config root resolution) call `.to_list()` exactly
    once at that point.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        Depset of Files from the transitive source closure.
    """
    return depset(transitive = [dep[DartInfo].transitive_srcs for dep in deps])

def collect_transitive_resources(deps):
    """Collect all transitive `resources` files from DartInfo deps.

    The sibling of `collect_transitive_srcs`, for the non-Dart files a package
    ships inside `lib/`. Kept a separate call rather than folded into that one
    so every consumer has to say which of the two it means: staging a package
    whole wants both, feeding the compiler wants only the sources.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        Depset of Files from the transitive resource closure.
    """
    return depset(transitive = [dep[DartInfo].transitive_resources for dep in deps])

def sdk_path_from_dart(dart_file):
    """Returns the SDK installation root by stripping `/bin/dart` from a dart File path.

    AOT-compiled shims pass this via `--sdk-path` so the analyzer's
    `AnalysisContextCollection` can locate the SDK's libraries.

    Args:
      dart_file: The toolchain's `dart` executable File.

    Returns:
      The SDK root path string.
    """
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

# --- Native code-asset (gen_kernel --native-assets) helpers ---
#
# SKELETON STUBS: signatures exist so `dart_test`/`dart_binary` load and the
# unit tests fail on assertions rather than missing symbols. Implemented in a
# follow-up edit.

def target_dart_abi(ctx):
    """Returns the Dart code-asset ABI string for the target platform.

    Format `<os>_<arch>` (e.g. `macos_arm64`, `linux_x64`, `windows_x64`,
    `linux_riscv64`, `linux_arm`), matching
    `kTargetOperatingSystemName_kTargetArchitectureName` in the VM
    (`runtime/vm/ffi/native_assets.cc`) and the `TARGET_PLATFORMS` table in
    `toolchains_repo.bzl`. Reads `DART_ABI_CONSTRAINT_ATTRS` constraints.

    Args:
      ctx: The rule context (must spread `DART_ABI_CONSTRAINT_ATTRS` in attrs).

    Returns:
      The `<os>_<arch>` ABI string.
    """
    if ctx.target_platform_has_constraint(ctx.attr._os_macos[platform_common.ConstraintValueInfo]):
        os = "macos"
    elif ctx.target_platform_has_constraint(ctx.attr._os_linux[platform_common.ConstraintValueInfo]):
        os = "linux"
    elif ctx.target_platform_has_constraint(ctx.attr._os_windows[platform_common.ConstraintValueInfo]):
        os = "windows"
    else:
        fail("%s: code_assets require a macos/linux/windows target OS." % ctx.label)
    if ctx.target_platform_has_constraint(ctx.attr._cpu_arm64[platform_common.ConstraintValueInfo]):
        arch = "arm64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_x64[platform_common.ConstraintValueInfo]):
        arch = "x64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_riscv64[platform_common.ConstraintValueInfo]):
        arch = "riscv64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_arm[platform_common.ConstraintValueInfo]):
        arch = "arm"
    else:
        fail(("%s: code_assets require an aarch64, x86_64, riscv64 or armv7 " +
              "target CPU (Dart has no code-asset ABI name for others). Every " +
              "CPU rules_dart registers a toolchain for is covered; this fires " +
              "for a platform supplied by a downstream module.") % ctx.label)

    # The OS and CPU probes are independent, so a user-declared platform can
    # produce a combination Dart never ships (e.g. `macos_riscv64`). That hole
    # predates the riscv64/armv7 entries — `macos_arm` was already reachable —
    # and it surfaces as a `native_assets.yaml` key the VM never looks up
    # rather than as a build error. Not worth a validity table.
    return os + "_" + arch

def has_comma_define(defines):
    """Whether any `-D` declaration carries a comma in its value.

    `gen_kernel` splits `-D`/`--define` values on commas
    (`Parser._setOption`), so a comma-containing value only survives a
    whole-program compile when it runs a snapshot whose comma-splitting is
    disabled (see `comma_patch.dart`). A module compile takes its defines as
    a map and needs no patch. Callers run the toolchain's patched snapshot and pass
    the `--comma-patched-snapshot` marker when this returns True, and the
    pristine snapshot otherwise.

    Args:
      defines: Environment declarations, each `NAME=value` (the `-D` prefix
        the compiler takes is added by the caller, not present here).

    Returns:
      True when any entry contains a comma.
    """
    for define in defines:
        if "," in define:
            return True
    return False

def find_sdk_kernel_tools(dart_sdk_info):
    """Locates the gen_kernel toolchain files within the SDK tree.

    Returns a struct with the `dartaotruntime` executable, the
    `gen_kernel_aot.dart.snapshot`, and the `vm_platform_strong.dill` and
    `vm_platform_product.dill` Files, found by exact path under the SDK root
    within `dart_sdk_info.compile_files`. Searching the compile subset rather
    than `tool_files` means each file found is already an input of the action
    that runs it, and the search flattens a few dozen files rather than the
    whole SDK.

    The product platform is the one `dart compile exe` builds an AOT kernel
    against. Built against the strong platform instead, an `exe` comes out about
    15% larger, because the library set the frontend tree-shakes from differs.

    Args:
      dart_sdk_info: The `DartSdkInfo` from the toolchain.

    Returns:
      `struct(dartaotruntime, gen_kernel_snapshot, platform_dill,
      product_platform_dill, patched_gen_kernel)` of Files, where
      `patched_gen_kernel` is the toolchain's comma-splitting-disabled copy of
      `gen_kernel_snapshot`, or None when the toolchain declares none.
    """
    sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
    wanted = {
        "dartaotruntime": [
            sdk_root + "/bin/dartaotruntime",
            sdk_root + "/bin/dartaotruntime.exe",
        ],
        "gen_kernel_snapshot": [sdk_root + "/bin/snapshots/gen_kernel_aot.dart.snapshot"],
        "platform_dill": [sdk_root + "/lib/_internal/vm_platform_strong.dill"],
        "product_platform_dill": [sdk_root + "/lib/_internal/vm_platform_product.dill"],
    }
    found = {}

    # Analysis-time path probe for 4 files over the small compile subset.
    for f in dart_sdk_info.compile_files.to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    for key in wanted:
        if key not in found:
            fail(("find_sdk_kernel_tools: could not locate %s under SDK root " +
                  "%r (Dart %s). The SDK layout may have changed across " +
                  "versions; every Dart compile runs the gen_kernel " +
                  "snapshot.") %
                 (key, sdk_root, dart_sdk_info.version))
    return struct(
        dartaotruntime = found["dartaotruntime"],
        gen_kernel_snapshot = found["gen_kernel_snapshot"],
        platform_dill = found["platform_dill"],
        product_platform_dill = found["product_platform_dill"],
        patched_gen_kernel = getattr(dart_sdk_info, "patched_gen_kernel", None),
    )

def hook_errors(label, packages):
    """The error for a closure holding a package whose build hook cannot run.

    A member of a merged pub dependency cycle is compiled inside the merged
    library, so no library of its own runs its hook. Checked where an
    executable is built rather than when the repository is generated: the
    whole lock is materialised, and failing there would fail on packages
    nothing depends on.

    Args:
      label: The consuming target's label.
      packages: List of `DartPackageInfo` in the transitive closure.

    Returns:
      An error message string, or `None`.
    """
    errors = [pkg.hook_error for pkg in packages if getattr(pkg, "hook_error", "")]
    if not errors:
        return None
    return "%s:\n%s" % (label, "\n".join(["  - " + e for e in errors]))

def kernel_sdk_mismatch_error(label, attr_name, tool_target, expected_sdk_version):
    """Checks that a kernel-compiled tool target matches the executing Dart SDK version.

    A Dart kernel (`.dill`) file embeds the compiling SDK's binary format and
    platform summary hash, so it can only be executed by the exact Dart SDK
    version that compiled it. When `tool_target` carries `DartCompileInfo` with
    `compile_mode == "kernel"` and a recorded `sdk_version` that differs from
    `expected_sdk_version`, returns an analysis-time error message rather than
    letting the build fail at execution time with a VM SDK-hash or kernel-format
    crash.

    Args:
        label: The label of the consuming target or aspect context.
        attr_name: The attribute name through which `tool_target` was resolved.
        tool_target: The tool `Target` (or `None`).
        expected_sdk_version: The `DartSdkInfo.version` of the SDK that will
            execute the tool.

    Returns:
        An error message string when a kernel tool's `sdk_version` disagrees
        with `expected_sdk_version`, or `None` when compatible.
    """
    if tool_target == None or DartCompileInfo not in tool_target:
        return None
    info = tool_target[DartCompileInfo]
    if info.compile_mode != "kernel":
        return None
    compiled_version = getattr(info, "sdk_version", "")
    if not compiled_version or not expected_sdk_version:
        return None
    if compiled_version != expected_sdk_version:
        return (
            "%s: `%s` target %s was compiled to a Dart kernel (.dill) by Dart SDK %s, " +
            "but will be executed by Dart SDK %s. A kernel binary can only run on the " +
            "exact Dart SDK version that compiled it; ensure the tool is built in the " +
            "same toolchain configuration that executes it, or use `compile_mode = \"exe\"`."
        ) % (label, attr_name, getattr(tool_target, "label", tool_target), compiled_version, expected_sdk_version)
    return None
