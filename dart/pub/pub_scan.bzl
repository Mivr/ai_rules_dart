"""Runs the AOT header scanner over fetched pub archives.

Every site that unpacks third-party pub content calls `run_pub_archive_scan`
between fetching the archive and extracting it: hosted spokes, git spokes,
merged-cycle members (hosted and git), `pub.package()` repositories, and the
module extension's cycle-planning scratch. The scan refuses every hard-link
entry whatever its target, every symlink entry whose target is absolute or
climbs out of the package root, and every entry whose own path is absolute or
climbs out of the root — the same lexical rules the post-extraction walk
(`pub_symlink.bzl`) applies, so the two guards never disagree. The walk
itself is kept behind the scan: dangling links, chain escapes through
in-package links, and materialising in-package links as regular files all
behave as before.

The scan itself runs in the AOT-compiled `dart_pub_scanner` snapshot (see
`//dart/pub:pub_scanner.bzl`), built once per output base from
the default-toolchain SDK by the `dart` module extension. `run_pub_archive_scan`
runs the fetch host SDK's `dartaotruntime` over the snapshot with the archive
file, parses its one-JSON-verdict protocol, and fails the fetch with the
refusal diagnostic; `run_pub_archive_scans` scans a batch of archives in one
snapshot invocation (one JSON verdict per line, in argument order) and fails
on the first refusal in batch order. The per-entry classification
(`classify_archive_entry`) and the diagnostics (`archive_entry_error`,
`archive_path_error`) stay pure Starlark in `pub_archive_scan.bzl` so unit
tests cover every refusal shape without downloading anything, and so the
scanner and the walk share one message vocabulary.

The spoke-facing names live on this public module so rule sets outside
`//dart/pub` (notably `rules_flutter`) reuse the same scan and walk:
`PUB_SCANNER_LABEL` names the scanner snapshot, `run_pub_archive_scan` runs
it, and `check_package_symlinks` is the post-extraction walk.
"""

load("//dart/pub/private:pub_archive_scan.bzl", "archive_entry_error", "archive_path_error", _scan_error = "scan_error")
load("//dart/pub/private:pub_scanner_sdk.bzl", "scanner_runtime_label")
load("//dart/pub/private:pub_symlink.bzl", _check_package_symlinks = "check_package_symlinks")

# Labels of the scanner snapshot, resolved through this module's mapping
# (which imports `dart_pub_scanner` from the `dart` extension). The build
# picks one by host OS; merely naming the other is harmless, since a Label
# only fetches its repository when resolved through `ctx.path`. The snapshot
# is not executed directly: the fetch host SDK's `dartaotruntime` (resolved
# through `scanner_runtime_label`, from the same host SDK repository the
# snapshot compiled from) runs it.
PUB_SCANNER_LABEL = Label("@dart_pub_scanner//:scanner")
PUB_SCANNER_WINDOWS_LABEL = Label("@dart_pub_scanner//:scanner.exe")

# The post-extraction walk, re-exported so other rule sets share one guard.
check_package_symlinks = _check_package_symlinks

def _scanner_label(ctx):
    """Returns the scanner Label for the fetch host's OS."""
    if ctx.os.name.lower().startswith("windows"):
        return PUB_SCANNER_WINDOWS_LABEL
    return PUB_SCANNER_LABEL

def _scan_failure(package_name, detail):
    """Fails the fetch when the archive cannot be scanned exactly."""
    fail(_scan_error(package_name, detail))

def _refusal_failure(package_name, verdict):
    """Fails the fetch with a parsed refusal verdict, or a scan failure."""
    refusal = verdict.get("refusal", None)
    if refusal != None:
        kind = refusal.get("kind", "")
        if kind == "path":
            fail(archive_path_error(package_name, refusal.get("path", "")))
        fail(archive_entry_error(package_name, refusal.get("path", ""), kind, refusal.get("target", "")))
    _scan_failure(package_name, verdict.get("unscannable", "the header scanner printed an unreadable verdict"))

def run_pub_archive_scans(ctx, archives):
    """Fails the fetch when any of the archives holds a refused entry.

    Runs the `dart_pub_scanner` snapshot once over every archive file — before
    the extractor trusts any of them, before a BUILD file is written, a
    pubspec is read, or a consumer can see a tree — and fails with the first
    refusal diagnostic in batch order. A scanner crash, a verdict line count
    that does not match the batch, an unreadable verdict, or an unscannable
    archive fails the fetch closed rather than trusting bytes the scan did
    not read exactly.

    Works from repository rules and module extensions alike: both contexts
    offer `ctx.path`, `ctx.execute` and `ctx.os`.

    Args:
      ctx: The repository or module-extension context fetching the packages.
      archives: A list of structs with `archive` (the archive file: a
        repo-relative path string, a `Path`, or a `Label`, resolved through
        `ctx.path`) and `name` (the pub package the archive was fetched
        for), in the order refusals report.
    """
    if not archives:
        return
    runtime = str(ctx.path(scanner_runtime_label(ctx.os)))
    snapshot = str(ctx.path(_scanner_label(ctx)))
    paths = [str(ctx.path(a.archive)) for a in archives]
    result = ctx.execute([runtime, snapshot] + paths, quiet = True, timeout = 600)
    if result.return_code != 0:
        output = (result.stderr if result.stderr else result.stdout).strip()
        tail = output[-2000:] if len(output) > 2000 else output
        _scan_failure(archives[0].name, "the header scanner failed (exit %d): %s" % (result.return_code, tail))
    lines = [line for line in result.stdout.split("\n") if line.strip() != ""]
    if len(lines) != len(archives):
        _scan_failure(archives[0].name, "the header scanner printed %d verdicts for %d archives" % (len(lines), len(archives)))
    for i in range(len(archives)):
        if not lines[i].startswith("{"):
            _scan_failure(archives[i].name, "the header scanner printed an unreadable verdict")
        verdict = json.decode(lines[i])
        if not verdict.get("ok", False):
            _refusal_failure(archives[i].name, verdict)

def run_pub_archive_scan(ctx, archive_path, package_name):
    """Fails the fetch when the archive at `archive_path` holds a refused entry.

    Scans the one archive through `run_pub_archive_scans` — the same
    snapshot invocation, the same verdict protocol, the same refusal
    diagnostics — so single-archive sites (spokes, `pub.package()`) and the
    planning batch share one code path.

    Args:
      ctx: The repository or module-extension context fetching the package.
      archive_path: The archive file: a repo-relative path string, a `Path`,
        or a `Label`, resolved through `ctx.path`.
      package_name: The pub package the archive was fetched for.
    """
    run_pub_archive_scans(ctx, [struct(archive = archive_path, name = package_name)])
