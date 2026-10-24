"""Addresses the host SDK's scanner files through this module's repo mapping.

`pub_scanner_repo.bzl` (the scanner compile) and `pub_scan.bzl` (running the
scanner over each fetched archive) both need the same two things: the fetch
host's SDK platform key and apparent labels of SDK files. They live here so
the compile and every scan site resolve the identical SDK files — the link
step's `gen_snapshot`, and the runtime that executes the snapshot, come from
the same host SDK repository the front end compiled from. Labels resolve
through this module's own repo mapping (which imports every `@dart_<platform>`
repository from the `dart` extension), so they keep working whatever local
name a consumer gives this module. `ctx.path` reads an SDK file without
`exports_files` getting in the way; the files stay inputs to the compile or
the scan invocation, never bytes in a repository's output.
"""

load("//dart/private:toolchains_repo.bzl", "PLATFORMS")

def scanner_platform_key(os):
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

def scanner_sdk_file(platform, path):
    """Labels one SDK tool file inside the host SDK repository.

    Args:
      platform: The host platform key from `scanner_platform_key`.
      path: The file's path inside the SDK repository.

    Returns:
      The apparent label of the SDK file.
    """
    return Label("@dart_%s//:%s" % (platform, path))

def scanner_runtime_label(os):
    """Labels the host SDK's AOT runtime, which executes scanner snapshots.

    Args:
      os: The host `os` struct (`ctx.os`).

    Returns:
      The apparent label of `bin/dartaotruntime` in the host SDK repository.
    """
    platform = scanner_platform_key(os)
    exe_suffix = ".exe" if os.name.lower().startswith("windows") else ""
    return scanner_sdk_file(platform, "bin/dartaotruntime" + exe_suffix)
