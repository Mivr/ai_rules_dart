"""Compile of the pub archive header scanner to a native executable.

`pub_scanner_repo_impl` is the implementation behind the one shared
`dart_pub_scanner` repository holding the `pub_scan.dart` header scanner
compiled to a native executable. The repository rule itself lives in the
public `//dart/pub:pub_scanner.bzl` entrypoint, which the `dart` module
extension calls once beside `dart_register_toolchains` for the
default-toolchain SDK (a repository rule cannot be imported across files
under a private name, so the rule object lives beside its only caller).
The compile runs once per output base from the default-toolchain SDK
the `dart` module extension selected: the front end (`dartaotruntime`
running `gen_kernel_aot.dart.snapshot` against the product platform)
compiles the source with stable `org-dartlang-root` URIs rooted at this
repository, so no absolute host path lands in the kernel, and `dart compile
exe` then links the kernel the same way `dart_binary` links an `exe` —
kernels and executables built from the same source in different absolute
directories are byte-identical. The Starlark half of the scan
(`//dart/pub:pub_scan.bzl`) runs that executable over each fetched archive
before `ctx.extract` sees it.

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

load("//dart/private:toolchains_repo.bzl", "PLATFORMS")

def _platform_key(os):
    """Maps the fetch host to the host SDK repository's platform key.

    `dart_register_toolchains` names SDK repositories `<base>_<platform>`
    with keys like `linux-x64`; the scanner compiles and runs on the fetch
    host, so it comes from the host's SDK.

    Args:
      os: The host `os` struct (`ctx.os`).

    Returns:
      The platform key (e.g. `"linux-x64"`), failing closed on a host with
      no SDK repository.
    """
    name = os.name.lower()
    arch = os.arch.lower()
    if name.startswith("linux"):
        os_part = "linux"
    elif name.startswith("mac") or name.startswith("darwin"):
        os_part = "macos"
    elif name.startswith("windows"):
        os_part = "windows"
    else:
        fail("the pub archive scanner needs a Linux, macOS or Windows fetch host, got os %r" % os.name)
    if arch == "amd64" or arch == "x86_64":
        arch_part = "x64"
    elif arch == "aarch64" or arch == "arm64":
        arch_part = "arm64"
    else:
        fail("the pub archive scanner needs an x64 or arm64 fetch host, got arch %r" % os.arch)
    platform = os_part + "-" + arch_part
    if platform not in PLATFORMS:
        fail("the pub archive scanner needs a host SDK repository, and there is none for fetch host %r" % platform)
    return platform

def _sdk_file(platform, path):
    """Labels one SDK tool file inside the host SDK repository.

    The apparent label resolves through this module's own repo mapping, which
    imports every `@dart_<platform>` repository from the `dart` extension, so
    it keeps working whatever local name a consumer gives this module and
    whatever canonical name version overrides assign it. `ctx.path` reads the
    file without `exports_files` getting in the way; the paths stay inputs to
    this repository's compile, never bytes in its output.

    Args:
      platform: The host platform key from `_platform_key`.
      path: The file's path inside the SDK repository.

    Returns:
      The apparent label of the SDK file.
    """
    return Label("@dart_%s//:%s" % (platform, path))

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
    """Compiles the scanner source to the native executable.

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

    # Link the kernel the way `dart compile exe` links a `dart_binary` `exe`:
    # from the kernel, so nothing about this machine leaks into the output.
    link = ctx.execute(
        [sdk_dart, "compile", "exe", "-o", exe_path, dill_path],
        environment = env,
        quiet = True,
        timeout = 600,
    )
    if link.return_code != 0:
        _fail_result(ctx, "the scanner exe link", link)
    ctx.delete(dill_path)
    ctx.file(
        "BUILD.bazel",
        "exports_files([\"%s\"])\n" % exe_name,
    )
