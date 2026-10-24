"""Compile of the pub archive header scanner to a native AOT snapshot.

`pub_scanner_repo_impl` is the implementation behind the one shared
`dart_pub_scanner` repository holding the `pub_scan.dart` header scanner
compiled to a native AOT snapshot. The repository rule itself lives in the
public `//dart/pub:pub_scanner.bzl` entrypoint, which the `dart` module
extension calls once beside `dart_register_toolchains` for the
default-toolchain SDK (a repository rule cannot be imported across files
under a private name, so the rule object lives beside its only caller).
The compile runs once per output base from the default-toolchain SDK
the `dart` module extension selected: the front end (`dartaotruntime`
running `gen_kernel_aot.dart.snapshot` against the product platform)
compiles the source with stable `org-dartlang-root` URIs rooted at this
repository, so no absolute host path lands in the kernel, and `gen_snapshot`
then links the kernel straight to an `app-aot-elf` snapshot — skipping the
`dart compile exe` wrapper, which would boot the whole `dartdev` JIT just to
invoke the same `gen_snapshot` and link a self-contained executable around
the snapshot. The snapshot holds no absolute host path either, so snapshots
linked from the same source in different absolute directories are
byte-identical, and the fetch host's `dartaotruntime` runs the snapshot over
each archive (see `//dart/pub:pub_scan.bzl`).

Attrs carry the scanner source as text (so editing the source recompiles)
and the SDK version (so a toolchain change recompiles too). The compile
tools come from the default toolchain's host SDK repository, addressed by
apparent label (`@dart_<platform>`, resolved through this module's own repo
mapping — the same way `PUB_SCANNER_LABEL` in `//dart/pub:pub_scan.bzl`
resolves `@dart_pub_scanner`): this module's `MODULE.bazel` imports every
host SDK repository from the `dart` extension, and its own non-dev
`dart.toolchain` tag guarantees the `dart` registration that creates them,
so the labels resolve in every consumer build without spelling any canonical
name by hand. Nothing is written outside this repository's directory, and no
host tool beyond the SDK itself is consulted.
"""

load("//dart/pub/private:pub_scanner_sdk.bzl", _platform_key = "scanner_platform_key", _sdk_file = "scanner_sdk_file")

def _fail_result(ctx, what, result):
    """Fails the fetch with the tail of a failed compile step's output."""
    output = (result.stderr if result.stderr else result.stdout).strip()
    tail = output[-2000:] if len(output) > 2000 else output
    fail("pub scanner repository \"%s\": %s failed (exit %d): %s" % (ctx.name, what, result.return_code, tail))

def _home_env(dart_exe):
    """Scrubs the home directory out of the compile environment.

    The SDK writes state under the user's home; clearing it keeps the compile
    from reading or writing a shared host directory, mirroring
    `writable_home_env` in `//dart/private:common.bzl` without depending on
    it: this repository cannot load the toolchain it is compiled from.
    """
    if dart_exe.endswith(".exe"):
        return {"USERPROFILE": "", "LOCALAPPDATA": ""}
    return {"HOME": ""}

def pub_scanner_repo_impl(ctx):
    """Compiles the scanner source to the native AOT snapshot.

    See the module docstring for the compile layout.

    Args:
      ctx: The scanner repository context; the attrs carry the source text
        and the SDK version, and the host SDK comes from this module's own
        repo mapping.
    """
    ctx.file("pub_scan.dart", ctx.attr.scanner_src)
    exe_suffix = ".exe" if ctx.os.name.lower().startswith("windows") else ""
    exe_name = "scanner" + exe_suffix
    platform = _platform_key(ctx.os)
    sdk_dart = str(ctx.path(_sdk_file(platform, "bin/dart" + exe_suffix)))
    repo_dir = str(ctx.path("pub_scan.dart").dirname)
    dill_path = repo_dir + "/scan.dill"
    exe_path = repo_dir + "/" + exe_name
    env = _home_env(sdk_dart)

    # Front end first, from sources named by stable URIs: the kernel records
    # `org-dartlang-root:///pub_scan.dart`, never the repository's absolute
    # path, which is what keeps the executable identical across output bases.
    # Flags mirror the `exe` front end in `//dart/private:dart_compile.bzl`.
    front = ctx.execute(
        [
            str(ctx.path(_sdk_file(platform, "bin/dartaotruntime" + exe_suffix))),
            str(ctx.path(_sdk_file(platform, "bin/snapshots/gen_kernel_aot.dart.snapshot"))),
            "--platform",
            str(ctx.path(_sdk_file(platform, "lib/_internal/vm_platform_product.dill"))),
            "--filesystem-scheme",
            "org-dartlang-root",
            "--filesystem-root",
            repo_dir,
            "-Ddart.vm.product=true",
            "-Ddart.vm.asan=false",
            "-Ddart.vm.msan=false",
            "-Ddart.vm.tsan=false",
            "--aot",
            "--tfa",
            "--no-embed-sources",
            "-o",
            dill_path,
            "org-dartlang-root:///pub_scan.dart",
        ],
        environment = env,
        quiet = True,
        timeout = 600,
    )
    if front.return_code != 0:
        _fail_result(ctx, "the scanner front-end compile", front)

    # Link the kernel straight with the SDK's `gen_snapshot`: `dart compile
    # exe` would boot the `dartdev` JIT only to invoke this same tool and
    # then link a self-contained executable around the snapshot. The fetch
    # host's `dartaotruntime` runs the snapshot directly, so the executable
    # wrapper is pure overhead. The snapshot records no host path (the kernel
    # carries stable `org-dartlang-root` URIs), keeping it byte-identical
    # across output bases.
    link = ctx.execute(
        [
            str(ctx.path(_sdk_file(platform, "bin/utils/gen_snapshot" + exe_suffix))),
            "--snapshot_kind=app-aot-elf",
            "--elf=" + exe_path,
            dill_path,
        ],
        environment = env,
        quiet = True,
        timeout = 600,
    )
    if link.return_code != 0:
        _fail_result(ctx, "the scanner snapshot link", link)
    ctx.delete(dill_path)
    ctx.file(
        "BUILD.bazel",
        "exports_files([\"%s\"])\n" % exe_name,
    )
