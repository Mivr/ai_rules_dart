#!/usr/bin/env python3
"""Speed-of-light (SOL) cost for the Flutter perf bench.

For each bench configuration (iOS, Android and Web; release and debug) and
each scenario (``clean``, ``app_edit``, ``core_edit``, ``api_edit``) this tool measures
two numbers in the same unit, whole-tree user+sys CPU seconds:

- the Bazel cost: for ``clean``, the whole ``bazel --batch build``
  process tree (Bazel's own work plus every action), measured with wait4
  rusage deltas, which include reaped descendants on both macOS and
  Linux; for the edit flows, the same cost measured against a warm Bazel
  server (``tools/perf/warm_server.py``): the client plus the server
  tree's growth during the command. A developer edits against a warm
  server, while ``--batch`` pays JVM start and a cold load and analysis
  on every edit, so the edit number follows the developer;
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs), run by hand in order. The SOL number is the sum of
  the chain steps' own process-tree CPU: the driver's own cost (loading
  the log, hashing, moving files) is never included.

A host-tool build is a spawn whose declared outputs land in an exec
configuration (``bazel-out/*-exec-*/``); those are not part of the chain
(building Bazel's helper tools is part of the gap). Every other executed
spawn runs, whatever tool binary it invokes: an action that runs an
exec-built tool to produce target-configuration outputs (the kernel
compile, for example) belongs in the chain. Steps whose outputs did not
change for an edit are skipped as a person would skip them: the
execution log records executed spawns only.

Proof the SOL did the same work: each chain step runs as Bazel runs it
(its declared outputs are removed before it starts), steps run in
dependency order even for edges the execution log never records (a
step whose input is, or resolves to, another step's output runs after
it), and the scenario's final outputs are moved aside before the chain
and hashed after. device_release hashes the App.framework binary;
sim_debug hashes every file in the final app bundle's payload (an
.ipa archive's entries, or every file under an .app directory),
compared by entry path and content: archive metadata such as zip
timestamps is not part of the proof. Android hashes every entry of each
declared .apk/.aab archive the same way; Web hashes every file under
each declared web output directory. The verify set comes from
declared outputs only, never a glob over bazel-out. A step that exits
non-zero, times out or cannot start — a step that would start while an
input is still a moved-aside output no earlier step re-created — or
any verify entry that differs afterwards — reports ``identical``
false with no SOL number. Bazel's outputs are moved back afterwards
and chain-created files no step declares are removed, so a chain can
never perturb the next incremental build's action cache.

Every flow also carries a small ``profile`` record, always on, with no
command lines: ``jvm`` is Bazel's own CPU from the build's ``--profile``
JSON trace (the "CPU usage (Bazel)" counter integrated over time and
split at the build-phase markers; the counter starts after JVM launch,
so launch CPU lands in ``residual``), ``host_tools`` replays the
chain-excluded host-tool builds under the same wait4 method after the
chain restores Bazel's outputs (a host build that fails to replay is
recorded, not fatal), and ``residual`` is ``bazel - jvm - sol -
host_tools``, never clamped — a failed chain has no SOL number, and
the record says so and substitutes the chain CPU instead. The gzipped
trace profiles and execution logs behind each record are uploaded as
the ``ios-profile`` artifact (no build outputs).

Subcommands: ``run`` measures repeats, ``chain`` runs one chain (an
unmeasured child process), ``summarize`` writes medians into
``<platform>-sol.json`` (``ios``, ``android`` or ``web``).
"""

import argparse
import gzip
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_flags import parse_bazel_flags  # noqa: E402
from bench_flags import validate_bazel_flags  # noqa: E402
from bench_flags import worker_steps as count_worker_steps  # noqa: E402
from execlog import load_spawns  # noqa: E402
from replay import (  # noqa: E402
    TIME_BIN,
    builds_host_tool,
    chain_all,
    order_chain_spawns,
    run_chain_step,
    select_chain_spawns,
    spawn_output_paths,
    spawn_recorded_digests,
    tail_lines,
)
from run_rep import (  # noqa: E402
    CONFIG_ORDER,
    CONFIGS,
    DEFAULT_MIN_CLEAN_ACTIONS,
    SCENARIOS,
    apply_edit,
    check_clean_actions,
    make_writable_tree,
    real_run,
    reset_work,
    shutdown,
)
from traceprofile import parse_jvm_profile  # noqa: E402
import warm_server  # noqa: E402
from floor_flow import floor_fields  # noqa: E402
from floor_summary import run_exit  # noqa: E402
from peak_rss import run_peak  # noqa: E402
# command_prefix and startup_options are re-exported: sol_test uses them.
from sol_argv import (  # noqa: E402,F401
    build_argv,
    command_prefix,
    cquery_argv,
    info_argv,
    out_base_of,
    startup_options,
)
from sol_warmup import run_warm_ups  # noqa: E402
from sol_errors import error_record  # noqa: E402,F401
from sol_errors import write_error_records  # noqa: E402
from sol_summary import print_flow_lines  # noqa: E402
from floor_flow import snapshot_sources  # noqa: E402
from sol_summary import (  # noqa: E402
    BATCH_METHOD,
    WARM_METHOD,
    _CONFIG_PLATFORM,
    _RECORD,
    collect_runner_info,
    configs_for_platform,
    flow_id,
    load_sol_records,
    pick_unit,
    present_platforms,
    rep_sort_key,
    summarize_bazel_parts,
    summarize_configs,
    summarize_flow,
    summarize_host_tools,
    summarize_jvm,
    summarize_profile,
    summarize_sol,
    summarize_worker_steps,
    write_platform_summaries,
    write_summary,
)

_EDITS = dict(SCENARIOS)
_CHAIN_REPORT = "chain.json"


def select_sol_spawns(spawns):
    """Runnable SOL chain: every executed spawn that is not a host build.

    Delegates to replay's output-based selection: a spawn is a host-tool
    build only when its declared outputs land in an exec configuration,
    never because its argv names an exec-built tool.
    """
    return select_chain_spawns(spawns)


def cpu_seconds(cost):
    """user+sys CPU seconds of a measurement, or None when unreported."""
    if cost.get("user_s") is None or cost.get("sys_s") is None:
        return None
    return cost["user_s"] + cost["sys_s"]


def sha256_file(path):
    """Hex digest of a file, or None when it is missing/unreadable.

    None is not swallowed: callers record it and any mismatch (including
    a missing file) reports identical=false.
    """
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def snapshot_hashes(paths):
    """{path: hex digest} over the verify files, in sorted order."""
    return {path: sha256_file(path) for path in sorted(paths)}


def hashes_match(before, after):
    """Whether two snapshots prove the chain reproduced Bazel's outputs."""
    return (bool(before) and before == after
            and all(v is not None for v in before.values()))


def path_depth(path):
    """Sort key: parents before children (fewer separators first)."""
    return (path.count(os.sep), path)


def covered_by(path, roots):
    """Whether path equals or sits under one of the moved roots."""
    return any(path == root or path.startswith(root + os.sep)
               for root in roots)


def move_aside_chain(step_outputs, backup_dir):
    """Moves every chain-step output aside; returns {original: backup}.

    Parents move before children, so a directory output moves whole. A
    verify file inside a moved directory travels with it; a verify file
    no running step declares is never passed here at all: it stays
    Bazel's own and its unchanged bytes count as proof. A missing path
    fails loudly (after moving back what was moved): the chain must
    recreate exactly what Bazel wrote.
    """
    shutil.rmtree(backup_dir, ignore_errors=True)
    os.makedirs(backup_dir, exist_ok=True)
    mapping = {}
    try:
        for path in sorted(set(step_outputs), key=path_depth):
            if covered_by(path, mapping):
                continue
            dst = os.path.join(backup_dir, "%d%s" % (
                len(mapping), os.path.splitext(path)[1]))
            os.rename(path, dst)
            mapping[path] = dst
    except OSError as exc:
        restore_tree(mapping)
        raise RuntimeError("sol move-aside of %s failed (%s)" % (path, exc))
    return mapping


def restore_tree(mapping):
    """Removes chain-written files and moves Bazel's originals back.

    Parents move back before children, and every parent directory is
    recreated: a step that failed before recreating its output directory
    (e.g. a tree artifact holding a verify file) restores exactly what
    Bazel left. A missing backup fails loudly instead of leaving the
    next build over a hole.
    """
    for path in sorted(mapping, key=path_depth):
        backup = mapping[path]
        if not os.path.exists(backup):
            raise RuntimeError("sol backup for %s is gone" % path)
        try:
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
            parent = os.path.dirname(path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.rename(backup, path)
        except OSError as exc:
            raise RuntimeError("sol restore of %s failed (%s)" % (path, exc))


def capture_bazel_output(argv, cwd):
    """stdout of a Bazel info/query command; stderr stays separate.

    Bazel relays JVM warnings on stderr. Merging the streams (as a
    combined capture does) lets a warning line corrupt parsed output
    paths, so stdout is captured alone and stderr is shown on failure.
    """
    proc = subprocess.run(
        list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError("bazel %s failed (exit %s): %s"
                           % (" ".join(list(argv)[1:]), proc.returncode,
                              tail_lines(proc.stderr)))
    return proc.stdout


def check_under_base(path, out_base, what):
    """Fails closed unless path exists under the output base."""
    abs_path = os.path.abspath(path)
    if not abs_path.startswith(os.path.abspath(out_base) + os.sep):
        raise RuntimeError("sol %s %s is not under output base %s"
                           % (what, path, out_base))
    if not os.path.exists(abs_path):
        raise RuntimeError("sol %s %s does not exist" % (what, path))
    return abs_path


def bazel_info(capture, work, out_base, key, batch):
    """One `bazel info` path (execroot, ...), validated.

    The mode has no default: callers must pass the flow's mode, so a
    warm flow can never send a `--batch` command at a running server.
    """
    out = capture(info_argv(out_base, key, batch), cwd=work)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError("bazel info %s returned %d line(s)"
                           % (key, len(lines)))
    return check_under_base(lines[0], out_base, "info " + key)


def query_target_files(capture, work, out_base, target, build_flags,
                         batch):
    """Absolute default output paths of a target via `cquery --output=starlark`.

    Every non-blank line must resolve to an existing path under the
    output base; anything else (a warning leaked into stdout, a format
    change) fails loudly instead of becoming a bogus verify path. The
    mode has no default and covers the execution-root lookup too: both
    commands run in the flow's mode, never `--batch` against a server.
    """
    out = capture(cquery_argv(out_base, target, build_flags, batch),
                  cwd=work)
    execroot = bazel_info(capture, work, out_base, "execution_root",
                          batch)
    listed = [line.strip() for line in out.splitlines() if line.strip()]
    files = [check_under_base(os.path.join(execroot, line), out_base,
                              "cquery " + target) for line in listed]
    if not files:
        raise RuntimeError("bazel cquery %s listed no files" % target)
    return files


def device_verify_files(target_files):
    """The App.framework binary among a framework target's outputs."""
    return sorted(p for p in target_files
                  if p.endswith("App.framework/App"))


def sim_bundle_roots(target_files):
    """App bundle roots among an ios_application's listed outputs."""
    roots = set()
    for path in target_files:
        if os.path.isdir(path) or path.endswith(".app"):
            roots.add(path)
        elif ".app/" in path:
            roots.add(path.split(".app/")[0] + ".app")
    return sorted(roots)


def sim_bundle_archives(target_files):
    """Declared .ipa bundle archives among a target's listed outputs."""
    return sorted(path for path in target_files if path.endswith(".ipa"))


def android_bundle_archives(target_files):
    """Declared Android .apk or .aab archives among a target's outputs."""
    return sorted(path for path in target_files
                  if path.endswith(".apk") or path.endswith(".aab"))


def web_bundle_roots(target_files):
    """The declared web deployment root among a target's output directories.

    A web build declares its bundle as a tree artifact, but a debug build
    also declares DDC staging directories beside it. The deployment root
    is the directory that carries the built index.html; a listing that
    declares exactly one directory has that directory as its root
    whatever it holds. Several directories with no deployment root are
    not a bundle, so the caller fails loudly instead of hashing staging
    trees.
    """
    dirs = sorted({path for path in target_files if os.path.isdir(path)})
    roots = [path for path in dirs
             if os.path.isfile(os.path.join(path, "index.html"))]
    if roots or len(dirs) != 1:
        return roots
    return dirs


def archive_entry_hashes(archive_path):
    """{entry path: hex digest} of a bundle archive's payload.

    Covers .ipa payloads as well as Android .apk/.aab archives. Only
    entry paths and contents prove the chain's work: archive metadata
    (timestamps, permissions, extra fields, entry order) is not part of
    the proof, so an archive whose bytes differ only in metadata still
    matches. An unreadable archive or one holding no files fails loudly.
    """
    import zipfile
    try:
        archive = zipfile.ZipFile(archive_path, "r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise RuntimeError("sol cannot read bundle archive %s (%s)"
                           % (archive_path, exc))
    try:
        entries = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            try:
                with archive.open(info, "r") as entry:
                    digest = hashlib.sha256(entry.read()).hexdigest()
            except (OSError, zipfile.BadZipFile, KeyError,
                    RuntimeError) as exc:
                raise RuntimeError("sol cannot read entry %s of %s (%s)"
                                   % (info.filename, archive_path, exc))
            entries[info.filename] = digest
    finally:
        archive.close()
    if not entries:
        raise RuntimeError("sol bundle archive %s holds no files"
                           % archive_path)
    return entries


ipa_entry_hashes = archive_entry_hashes


def app_dir_hashes(app_dir):
    """{relative path: hex digest} of every file under an .app directory.

    File symlinks hash by content; directory symlinks (macOS framework
    version links) hash by their target string. A dangling link hashes
    None and fails the proof closed, like any missing file. An empty
    bundle fails loudly.
    """
    entries = {}
    for dirpath, dirnames, filenames in os.walk(app_dir,
                                                followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries[os.path.relpath(full, app_dir)] = sha256_file(full)
        for name in dirnames:
            full = os.path.join(dirpath, name)
            if not os.path.islink(full):
                continue
            try:
                target = os.readlink(full)
            except OSError:
                target = None
            if target is None:
                entries[os.path.relpath(full, app_dir)] = None
            else:
                entries[os.path.relpath(full, app_dir)] = hashlib.sha256(
                    ("symlink->" + target).encode("utf-8")).hexdigest()
    if not entries:
        raise RuntimeError("sol app bundle %s holds no files" % app_dir)
    return entries


def plan_verify_snapshot(capture, work, out_base, execroot, config,
                           batch):
    """Discovers the verify set from declared outputs only, never a glob.

    device_release hashes the App.framework binary among the framework
    target's listed outputs. sim_debug hashes the final app bundle's
    payload: every entry of each listed .ipa archive, and every file
    under each listed .app directory (the kernel blob and the
    App.framework binary are among those files). Android configurations
    hash every entry of each declared .apk/.aab archive, ignoring zip
    metadata. Web configurations hash every file under each declared
    web output directory. Anything else — no bundle among the listed
    outputs — fails loudly instead of globbing bazel-out, whose
    leftovers are not this build's outputs. Returns an opaque plan;
    read_verify_snapshot reads it right now.
    """
    spec = CONFIGS[config]
    listed = query_target_files(capture, work, out_base, spec["target"],
                                spec["build_flags"], batch)
    platform = _CONFIG_PLATFORM[config]
    if platform == "ios" and config == "device_release":
        found = device_verify_files(listed)
        if not found:
            raise RuntimeError("sol found no verify files for %s" % config)
        return ("files", found)
    if platform == "android":
        archives = android_bundle_archives(listed)
        if not archives:
            raise RuntimeError(
                "sol found no bundle for %s (declared Android APK/AAB)"
                % config)
        return ("archives", archives, execroot)
    if platform == "web":
        roots = web_bundle_roots(listed)
        if not roots:
            raise RuntimeError(
                "sol found no bundle for %s (declared web output "
                "directory)" % config)
        return ("tree", roots, execroot)
    archives = sim_bundle_archives(listed)
    bundles = sim_bundle_roots(listed)
    if not archives and not bundles:
        raise RuntimeError("sol found no app bundle for %s" % config)
    return ("bundles", archives, bundles, execroot)


def _archive_snapshot(archives, base):
    """{bundle path::entry: digest} over every declared archive's payload."""
    snapshot = {}
    for archive in archives:
        prefix = os.path.relpath(archive, base) + "::"
        for entry, digest in archive_entry_hashes(archive).items():
            snapshot[prefix + entry] = digest
    return snapshot


def _tree_snapshot(roots, base):
    """{bundle path::relative file: digest} over every declared tree."""
    snapshot = {}
    for root in roots:
        prefix = os.path.relpath(root, base) + "::"
        for entry, digest in app_dir_hashes(root).items():
            snapshot[prefix + entry] = digest
    return snapshot


def read_verify_snapshot(plan):
    """{key: digest} over the planned verify set, read right now.

    Bundle keys are execroot-relative bundle paths plus "::" plus the
    entry path, so the chain record names payload entries portably; a
    bundle that reads empty fails loudly.
    """
    if plan[0] == "files":
        return snapshot_hashes(plan[1])
    if plan[0] == "archives":
        _, archives, execroot = plan
        snapshot = _archive_snapshot(archives,
                                     os.path.abspath(execroot))
    elif plan[0] == "tree":
        _, roots, execroot = plan
        snapshot = _tree_snapshot(roots, os.path.abspath(execroot))
    else:
        _, archives, bundles, execroot = plan
        base = os.path.abspath(execroot)
        snapshot = _archive_snapshot(archives, base)
        snapshot.update(_tree_snapshot(bundles, base))
    if not snapshot:
        raise RuntimeError("sol bundle payload is empty")
    return snapshot


def snapshot_tree(root):
    """Every path under root (files, links and dirs), absolute normpaths."""
    seen = {os.path.normpath(os.path.abspath(root))}
    if not os.path.isdir(root):
        return seen
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        seen.add(os.path.normpath(dirpath))
        for name in filenames:
            seen.add(os.path.normpath(os.path.join(dirpath, name)))
        for name in dirnames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                seen.add(os.path.normpath(full))
    return seen


def _is_protected(path, declared):
    """Whether a chain path is a declared output or covers one.

    A path equal to, under, or above a declared output stays: declared
    outputs are restored separately, and anything above one is a parent
    the restore walks back through.
    """
    for root in declared:
        if (path == root or path.startswith(root + os.sep)
                or root.startswith(path + os.sep)):
            return True
    return False


def _drop_chain_file(full):
    """Removes one undeclared chain file or link, loudly on failure.

    A removal failure raises RuntimeError naming the path: the next
    build must never run over a hole the sweep left behind.
    """
    try:
        os.remove(full)
    except OSError as exc:
        raise RuntimeError("sol cannot remove chain side effect %s "
                           "(%s)" % (full, exc))


def _sweep_dir_files(dirpath, filenames, base, declared, before,
                       removed):
    """Removes undeclared chain files in one directory; appends relpaths."""
    for name in filenames:
        full = os.path.normpath(os.path.join(dirpath, name))
        if full not in before and not _is_protected(full, declared):
            _drop_chain_file(full)
            removed.append(os.path.relpath(full, base))


def _sweep_dir_links(dirpath, dirnames, base, declared, before, removed):
    """Removes undeclared chain symlinks in one directory.

    Links hide in dirnames (os.walk lists them as dirs): a link the
    chain created is removed like a file, never descended into.
    """
    for name in list(dirnames):
        full = os.path.join(dirpath, name)
        if not os.path.islink(full):
            continue
        norm = os.path.normpath(full)
        if norm not in before and not _is_protected(norm, declared):
            _drop_chain_file(full)
            removed.append(os.path.relpath(norm, base))


def _sweep_dir_entries(dirpath, dirnames, filenames, base, declared,
                       before, removed):
    """Sweeps one directory's files, then its links, in walk order.

    One top-down os.walk pass calls this per directory, so a failure
    partway leaves the same tree as removing files-then-links per
    directory in walk order: earlier directories are already swept.
    """
    _sweep_dir_files(dirpath, filenames, base, declared, before, removed)
    _sweep_dir_links(dirpath, dirnames, base, declared, before, removed)


def _sweep_empty_dirs(base, declared, before):
    """Removes dirs the sweep emptied under base; returns relpaths.

    Bottom-up, so an emptied parent goes once its children are gone;
    base itself, Bazel's own paths and anything covering a declared
    output stay.
    """
    removed = []
    for dirpath, _, _ in os.walk(base, followlinks=False, topdown=False):
        norm = os.path.normpath(dirpath)
        if norm == base or norm in before or _is_protected(norm, declared):
            continue
        try:
            if not os.listdir(norm):
                os.rmdir(norm)
                removed.append(os.path.relpath(norm, base))
        except OSError as exc:
            raise RuntimeError("sol cannot remove chain side-effect dir "
                               "%s (%s)" % (norm, exc))
    return removed


def sweep_chain_side_effects(bazel_out, declared_outputs, before):
    """Removes chain-created files/dirs under bazel-out no step declares.

    Besides restoring every declared output, the chain must leave the
    execroot as Bazel left it: an unsandboxed step may leave files next
    to its declared output (an undeclared sibling of App.framework.zip,
    say), and those leftovers would both perturb the next incremental
    build and pollute any later proof. Anything under bazel-out that is
    neither Bazel's own (in before) nor a declared output (equal to,
    under, or above one) is removed: files and links first, then the
    emptied directories. Returns {"n": removed count, "paths": first 10,
    bazel-out relative}. A removal failure raises RuntimeError naming
    the path instead of leaving the next build over a hole.
    """
    base = os.path.abspath(bazel_out)
    declared = [os.path.normpath(path) for path in declared_outputs]
    removed = []
    if not os.path.isdir(base):
        return {"n": 0, "paths": []}
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        _sweep_dir_entries(dirpath, dirnames, filenames, base, declared,
                           before, removed)
    removed.extend(_sweep_empty_dirs(base, declared, before))
    removed = sorted(set(removed))
    return {"n": len(removed), "paths": removed[:10]}


def measure_process_tree(argv, cwd, _rss_read=None, _children=None):
    """Whole-tree user+sys CPU seconds of argv (wait4 rusage deltas).

    The same method on macOS and Linux, with no time binary:
    RUSAGE_CHILDREN includes reaped descendants, so the number covers
    the child plus every process it spawns (Bazel's own work plus every
    action for a build). Per-step instruction counters cannot do this:
    on macOS they describe the timed child alone, never its tree.
    """
    import resource
    start = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    returncode, peak = run_peak(argv, cwd, None, _rss_read, _children)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"instructions": None, "real_s": time.monotonic() - start,
            "user_s": after.ru_utime - before.ru_utime,
            "sys_s": after.ru_stime - before.ru_stime,
            "returncode": returncode, "method": "rusage-children",
            "peak_rss_mb": peak}


def measure_with_time(argv, cwd, time_bin=TIME_BIN):
    """Measures argv's whole process tree (kept CLI-compatible name).

    time_bin is accepted for compatibility and ignored: both numbers are
    whole-tree user+sys CPU seconds on every host, so there is exactly
    one CPU method and no platform-specific binary to miss.
    """
    del time_bin
    return measure_process_tree(argv, cwd)


def bazel_batch_build(args, config, log_path, profile_path):
    """Builds one scenario with `bazel --batch`, measured as one unit.

    The JSON trace profile (--profile) feeds the flow's jvm record; the
    execution log feeds the SOL chain and the host-tools replay.
    """
    spec = CONFIGS[config]
    argv = build_argv(out_base_of(args, config), config, log_path,
                      profile_path, True)
    cost = args.measure(argv, args.work)
    if cost["returncode"] != 0:
        raise RuntimeError("bazel --batch build %s failed (exit %s)"
                           % (spec["target"], cost["returncode"]))
    return cost


def bazel_warm_build(args, config, log_path, profile_path, server_pid):
    """Builds one scenario against the warm server, measured whole-tree.

    The same target, flags, execution log and trace profile as the batch
    form; only `--batch` is dropped, so the build runs on the config's
    server. The cost covers the client plus the server tree's growth
    (warm_server), with the per-part breakdown under "parts".
    """
    spec = CONFIGS[config]
    argv = build_argv(out_base_of(args, config), config, log_path,
                      profile_path, False)
    cost = args.measure_warm(argv, args.work, server_pid)
    if cost["returncode"] != 0:
        raise RuntimeError("bazel build %s failed (exit %s)"
                           % (spec["target"], cost["returncode"]))
    return cost


def server_pid_of(capture_server, work, out_base):
    """Starts (or reuses) the config's server; returns its pid, loudly.

    Any server-mode command starts the server; `info server_pid` also
    reports the pid the warm measurement attributes. A missing or
    non-numeric pid fails closed: without it there is no warm number.
    """
    out = capture_server(info_argv(out_base, "server_pid", False),
                         cwd=work)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError("bazel info server_pid returned %d line(s)"
                           % len(lines))
    try:
        pid = int(lines[0])
    except ValueError:
        raise RuntimeError("bazel info server_pid returned %r"
                           % (lines[0],))
    if pid <= 0:
        raise RuntimeError("bazel info server_pid returned %r"
                           % (lines[0],))
    return pid


def run_chain(log_path, execroot, report_path, timeout, runner=None):
    """Runs an execution log's SOL chain in order; writes its report."""
    spawns = load_spawns(log_path)
    report = chain_all(spawns, execroot, timeout, runner=runner)
    with open(report_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("replayed=%d failed=%d skipped=%s" % (
        report["n_replayed"], len(report["failed"]), report["skipped"]))
    return report


def run_chain_proc(args, log_path, execroot, report_path):
    """Runs the chain subcommand as a plain, unmeasured child process.

    The SOL number comes from the chain report (the steps' own CPU),
    never from timing this driver: its stdout and stderr stay attached
    so the job log shows what the chain did.
    """
    argv = [sys.executable, os.path.abspath(__file__), "chain",
            "--log", log_path, "--execroot", execroot,
            "--report", report_path, "--timeout", str(args.timeout)]
    proc = subprocess.run(list(argv), cwd=args.work, stdin=subprocess.DEVNULL,
                          check=False)
    return proc.returncode


def read_chain_report(report_path):
    """Chain report dict, or None when the chain never wrote one.

    None is not swallowed: the caller reports identical=false with a
    reason naming the missing report.
    """
    try:
        with open(report_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def verify_differences(before, after, execroot):
    """Verify entries that differ: {"n": count, "differ": first 10}.

    Each entry names the path with both digests ({path, before, after});
    at most 10 entries travel in the chain record, plus the total count.
    Absolute file paths show execroot-relative; bundle payload keys are
    already portable.
    """
    differ = []
    for key in sorted(set(before) | set(after)):
        if before.get(key) == after.get(key):
            continue
        if "::" in key:
            shown = key
        else:
            try:
                shown = os.path.relpath(key, execroot)
            except ValueError:
                shown = key
        differ.append({"path": shown, "before": before.get(key),
                       "after": after.get(key)})
    return {"n": len(differ), "differ": differ[:10]}


def output_drift(chainable, execroot):
    """Chain-step outputs differing from the log's digests, info only.

    Compares files the chain wrote against the digests the execution
    log recorded in actualOutputs. Missing files (steps never run),
    directories and unrecorded outputs are skipped; the count covers
    every differing file while paths keep the first 10, execroot
    relative. Never fails a flow: reproducibility detail, not proof.
    """
    base = os.path.abspath(execroot)
    differing = []
    for spawn in chainable:
        recorded = spawn_recorded_digests(spawn)
        if not recorded:
            continue
        resolved = {}
        for raw, digest in recorded.items():
            resolved[raw] = digest
            joined = (raw if os.path.isabs(raw)
                      else os.path.join(base, raw))
            resolved[os.path.normpath(joined)] = digest
        for path in spawn_output_paths(spawn, execroot):
            if path not in resolved or not os.path.isfile(path):
                continue
            if sha256_file(path) != resolved[path]:
                differing.append(os.path.relpath(path, base))
    differing = sorted(set(differing))
    return {"n": len(differing), "paths": differing[:10]}


def describe_chain(report, differ, drift=None):
    """Small per-flow chain record for ios-sol.json (no command lines)."""
    if drift is None:
        drift = {"n": 0, "paths": []}
    if report is None:
        return {"steps": {}, "skipped": {}, "failed": [],
                "ordering_failed": None,
                "verify_differ": differ, "output_drift": drift,
                "sol_cpu_s": None, "status": "no report"}
    steps = {}
    for mnemonic, entry in (report.get("by_mnemonic") or {}).items():
        cpu = None
        if (not entry.get("cpu_s_missing")
                and entry.get("user_s_total") is not None
                and entry.get("sys_s_total") is not None):
            cpu = entry["user_s_total"] + entry["sys_s_total"]
        steps[mnemonic] = {"count": entry.get("count", 0), "cpu_s": cpu}
    failed = report.get("failed") or []
    status = "failed" if failed else "ok"
    if report.get("ordering_failed") is not None:
        status = "ordering-failed"
    return {"steps": steps, "skipped": dict(report.get("skipped") or {}),
            "failed": [{"mnemonic": entry.get("mnemonic", ""),
                        "exit": entry.get("exit"),
                        "stderr_tail": entry.get("stderr_tail")}
                       for entry in failed],
            "ordering_failed": report.get("ordering_failed"),
            "verify_differ": differ, "output_drift": drift,
            "sol_cpu_s": report.get("sol_cpu_s"),
            "status": status}


def flow_reason(chain, exit_code):
    """One-line verdict reason for the job log and the flow record."""
    if chain["status"] == "no report":
        return "chain wrote no report (exit %s)" % (exit_code,)
    if chain.get("ordering_failed"):
        item = chain["ordering_failed"]
        return ("ordering failure: step %s needs %s (a moved-aside "
                "output no earlier step re-created)"
                % (item.get("mnemonic", ""), item.get("input", "")))
    if chain["failed"]:
        first = chain["failed"][0]
        reason = "step %s failed (exit %s)" % (first["mnemonic"],
                                               first["exit"])
    else:
        reason = "ok"
    differ = chain.get("verify_differ") or {"n": 0, "differ": []}
    if differ.get("n"):
        entries = differ.get("differ") or []
        shown = entries[0]["path"] if entries else "?"
        reason += "; verify differ: %d file(s), e.g. %s" % (
            differ["n"], shown)
    elif chain["failed"] and exit_code != 0:
        reason += "; chain exit %s" % (exit_code,)
    return reason


def chain_replayed(report_path):
    """Replayed-action count from a chain report (loud when missing)."""
    report = read_chain_report(report_path)
    if report is None or not isinstance(report.get("n_replayed"), int):
        raise RuntimeError("sol chain report %s unreadable" % report_path)
    return report["n_replayed"]


def save_gzipped(src, dst):
    """Gzips src to dst for the ios-profile artifact; fails loudly."""
    with open(src, "rb") as fin:
        data = fin.read()
    with open(dst, "wb") as fout:
        fout.write(gzip.compress(data, mtime=0))


def host_tool_spawns(spawns):
    """Splits host-tool builds into (runnable, skipped).

    The spawns the SOL chain leaves out as host-tool builds (declared
    outputs under an exec configuration); only executed spawns with a
    command replay, like the chain's own buckets.
    """
    runnable = []
    skipped = {}
    for spawn in spawns:
        if not builds_host_tool(spawn):
            continue
        if spawn.get("cacheHit"):
            skipped["cache hit"] = skipped.get("cache hit", 0) + 1
            continue
        if spawn.get("exitCode", 0) != 0:
            key = "bazel exit %s" % (spawn.get("exitCode"),)
            skipped[key] = skipped.get(key, 0) + 1
            continue
        if not spawn.get("commandArgs"):
            skipped["no command"] = skipped.get("no command", 0) + 1
            continue
        runnable.append(spawn)
    return (runnable, skipped)


def replay_host_spawns(spawns, execroot, timeout, backup_dir, runner=None):
    """Replays host-tool builds under the chain's CPU method.

    The spawns the SOL chain leaves out as host-tool builds run by hand
    (ordered as the chain orders them), every host-step output moved
    aside before the replay and Bazel's originals moved back after, as
    for the chain. A failed replay is recorded with its step, never
    fatal: the replay continues with the next spawn. Returns the
    ios-sol.json host_tools record (no command lines): the total and
    per-mnemonic CPU, the top 10 target labels by CPU (plus the per-target
    map summarize medians over), and any failed replays.
    """
    runnable, skipped = host_tool_spawns(spawns)
    if not runnable:
        return {"total": 0.0, "by_mnemonic": {}, "top_targets": [],
                "by_target": {}, "failed": [], "count": 0,
                "skipped": skipped}
    ordered = order_chain_spawns(runnable, execroot)
    if runner is None:
        runner = (lambda spawn: run_chain_step(spawn, execroot, timeout))
    step_outputs = []
    for spawn in ordered:
        step_outputs.extend(spawn_output_paths(spawn, execroot))
    bazel_out = os.path.join(execroot, "bazel-out")
    before_tree = snapshot_tree(bazel_out)
    try:
        aside = move_aside_chain(step_outputs, backup_dir)
    except (OSError, RuntimeError) as exc:
        return {"total": None, "by_mnemonic": {}, "top_targets": [],
                "by_target": {}, "failed": [], "count": len(ordered),
                "skipped": skipped,
                "error": "host-tools move-aside failed (%s)" % exc}
    by_mnemonic = {}
    by_target = {}
    failed = []
    try:
        for spawn in ordered:
            record = runner(spawn)
            mnemonic = spawn.get("mnemonic", "")
            target = spawn.get("targetLabel", "")
            if (record.get("user_s") is not None
                    and record.get("sys_s") is not None):
                cpu = record["user_s"] + record["sys_s"]
                by_mnemonic[mnemonic] = by_mnemonic.get(mnemonic, 0.0) + cpu
                by_target[target] = by_target.get(target, 0.0) + cpu
            if record.get("exit_code") != 0:
                failed.append({"mnemonic": mnemonic, "target": target,
                               "exit": record.get("exit_code"),
                               "stderr_tail": record.get("stderr_tail")})
    finally:
        swept = sweep_chain_side_effects(bazel_out, step_outputs,
                                         before_tree)
        restore_tree(aside)
    top = sorted(by_target.items(),
                 key=lambda item: (-item[1], item[0]))[:10]
    return {"total": (sum(by_mnemonic.values()) if by_mnemonic else None),
            "by_mnemonic": by_mnemonic,
            "top_targets": [[label, cpu] for label, cpu in top],
            "by_target": by_target, "failed": failed,
            "count": len(ordered), "skipped": skipped,
            "side_effects_removed": swept}


def read_jvm_cpu(profile_path):
    """Jvm record of a build trace profile; failures stay null, recorded."""
    try:
        return parse_jvm_profile(profile_path)
    except (OSError, ValueError) as exc:
        return {"total": None, "phases": {}, "error": str(exc)}


def build_profile(bazel_cpu, jvm, host, sol, chain):
    """Per-repeat profile: gap SOL (chain CPU when SOL missing), residual.

    A flow without a SOL number uses the chain's measured CPU in its
    place (sol_source says which: "sol" or "chain-cpu"). residual is the
    raw bazel - jvm - sol - host_tools value, never clamped; None while
    any part is missing.
    """
    if sol is not None:
        gap, source = sol["cpu_s"], "sol"
    else:
        gap, source = chain.get("sol_cpu_s"), "chain-cpu"
    parts = [bazel_cpu, jvm.get("total"), gap, host.get("total")]
    residual = None
    if all(part is not None for part in parts):
        residual = parts[0] - parts[1] - parts[2] - parts[3]
    return {"jvm": jvm, "host_tools": host, "sol_cpu_s": gap,
            "sol_source": source, "residual": residual}


def measure_scenario_build(args, config, scenario, batch,
                             server_pid=None):
    """Builds one scenario; returns its costs, paths and verify plan.

    The mode has no default: the clean flow passes batch, edit flows
    pass the server pid. The clean flow stays a `bazel --batch` build;
    edit flows build against the config's warm server. The execution
    log and the JSON trace profile (--profile) are gzipped into the scenario's record
    directory for the ios-profile artifact.
    """
    spec = CONFIGS[config]
    edit = _EDITS[scenario]
    swap = snapshot_sources(args, config, scenario)
    if edit is not None:
        apply_edit(args.run, args.tools, args.work, edit)
    log_path = os.path.join(args.work, "execlog-sol-%s.json" % scenario)
    profile_path = os.path.join(args.work, "trace-sol-%s.json" % scenario)
    if batch:
        bazel_cost = bazel_batch_build(args, config, log_path,
                                       profile_path)
    else:
        bazel_cost = bazel_warm_build(args, config, log_path,
                                      profile_path, server_pid)
    if scenario == "clean":
        check_clean_actions(log_path, spec["target"],
                            args.min_clean_actions)
    out_base = out_base_of(args, config)
    capture = args.capture if batch else args.capture_server
    execroot = bazel_info(capture, args.work, out_base,
                          "execution_root", batch)
    bazel_out = os.path.join(execroot, "bazel-out")
    if os.path.isdir(bazel_out):
        make_writable_tree(bazel_out)
    plan = plan_verify_snapshot(capture, args.work, out_base,
                                execroot, config, batch)
    record_dir = os.path.join(args.results, "sol", config, scenario,
                              "rep%d" % args.rep)
    os.makedirs(record_dir, exist_ok=True)
    save_gzipped(log_path, os.path.join(record_dir, "execlog.json.gz"))
    save_gzipped(profile_path, os.path.join(record_dir, "trace.json.gz"))
    return argparse.Namespace(
        bazel_cost=bazel_cost, log_path=log_path,
        profile_path=profile_path, execroot=execroot, bazel_out=bazel_out,
        plan=plan, record_dir=record_dir, swap=swap,
        report_path=os.path.join(record_dir, _CHAIN_REPORT))


def prove_chain_outputs(args, built, chainable, before, backup_dir):
    """Runs the SOL chain with outputs moved aside; returns the proof.

    Returns (chain, after, exit_code, report): the ios-sol.json chain
    record, the after-chain verify snapshot, the chain exit code and its
    report (None when the chain never wrote one).
    """
    step_outputs = []
    for spawn in chainable:
        step_outputs.extend(spawn_output_paths(spawn, built.execroot))
    before_tree = snapshot_tree(built.bazel_out)
    aside = move_aside_chain(step_outputs, backup_dir)
    try:
        exit_code = run_chain_proc(args, built.log_path, built.execroot,
                                   built.report_path)
        report = read_chain_report(built.report_path)
        drift = output_drift(chainable, built.execroot)
        try:
            after = read_verify_snapshot(built.plan)
            read_error = None
        except RuntimeError as exc:
            # A missing or unreadable verify file or bundle after the
            # chain is a flow verdict, not a config error: a step that
            # failed before the final bundle was written leaves nothing
            # to hash. The empty snapshot differs from every before
            # entry, so the reason names the failed step and the missing
            # file; the run continues with the next scenario. Only a
            # fault in the tool itself escalates to a config error.
            after = {}
            read_error = str(exc)
    finally:
        swept = sweep_chain_side_effects(built.bazel_out, step_outputs,
                                         before_tree)
        restore_tree(aside)
    differ = verify_differences(before, after, built.execroot)
    if read_error is not None and differ["n"] == 0:
        differ = {"n": 1, "differ": [
            {"path": "(unreadable verify set)", "before": None,
             "after": read_error}]}
    chain = describe_chain(report, differ, drift)
    chain["side_effects_removed"] = swept
    return (chain, after, exit_code, report)


def run_sol_scenario(args, config, scenario, batch,
                       server_pid=None, warm_up=None):
    """Builds one scenario, runs its SOL chain, proves the outputs.

    The mode has no default: callers pass the flow's mode explicitly.
    An edit flow's warm-up record is stored on its record as `warm_up`."""
    built = measure_scenario_build(args, config, scenario, batch,
                                   server_pid)
    before = read_verify_snapshot(built.plan)
    spawns = load_spawns(built.log_path)
    chainable, _ = select_sol_spawns(spawns)
    chain, after, exit_code, report = prove_chain_outputs(
        args, built, chainable, before,
        os.path.join(args.work, "sol-backup-" + scenario))
    failed = bool(chain["failed"]) or chain["status"] != "ok"
    identical = (hashes_match(before, after) and not failed
                 and not chain["verify_differ"]["n"])
    if identical:
        sol = {"cpu_s": chain["sol_cpu_s"],
               "real_s": (report or {}).get("sol_real_s")}
    else:
        sol = None
    if sol is not None and sol["cpu_s"] is None:
        identical = False
        sol = None
    host = replay_host_spawns(
        spawns, built.execroot, args.timeout,
        os.path.join(args.work, "sol-host-backup-" + scenario))
    bazel_cpu = cpu_seconds(built.bazel_cost)
    profile = build_profile(bazel_cpu, read_jvm_cpu(built.profile_path),
                            host, sol, chain)
    record = {"flow": flow_id(config, scenario), "config": config,
              "scenario": scenario,
              "method": BATCH_METHOD if batch else WARM_METHOD,
              "bazel": {"cpu_s": bazel_cpu,
                        "real_s": built.bazel_cost["real_s"],
                        "peak_rss_mb": built.bazel_cost.get("peak_rss_mb")},
              "sol": sol,
              "identical": identical,
              "reason": flow_reason(chain, exit_code),
              "n_sol_actions": (report or {}).get("n_replayed", 0),
              "worker_steps": count_worker_steps(chainable),
              "verify": {"before": before, "after": after},
              "chain": chain,
              "profile": profile}
    if not batch:
        record["bazel_parts"] = built.bazel_cost["parts"]
    if warm_up is not None:
        record["warm_up"] = warm_up
    record.update(floor_fields(args, config, scenario, built, built.swap))
    with open(os.path.join(built.record_dir, _RECORD), "w", encoding="utf-8",
              newline="\n") as fh:
        fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def run_sol_rep(args, rep, configs):
    """One repeat: fresh workspace per config, cumulative edits per config.

    The clean flow stays a `bazel --batch` build. After its chain and
    replay have restored Bazel's outputs, a server starts on the same
    output base (same startup options minus `--batch`); one unmeasured
    warm-up build must execute zero actions, an unmeasured app edit and
    build then warm the workers (its record rides on every edit flow as
    `warm_up`), and each edit flow builds against that server. While the server is up every Bazel
    command on the output base goes through it, never `--batch`, and the
    server shuts down after the config's last flow and on every error
    path: no server outlives its config. An unexpected error in one
    config records that config's remaining flows with the error as their
    reason and lets the other config run: one failure never loses the
    rest of the run. Returns (records, had_errors).
    """
    args.rep = rep
    records = {}
    had_errors = False
    for config in configs:
        reset_work(args.pristine, args.work)
        out_base = out_base_of(args, config)
        shutil.rmtree(out_base, ignore_errors=True)
        flows = {}
        server_started = False
        try:
            flows["clean"] = run_sol_scenario(args, config, "clean",
                                                  batch=True)
            server_pid = server_pid_of(args.capture_server, args.work,
                                       out_base)
            server_started = True
            warm_up = run_warm_ups(args, config)
            for scenario, _ in SCENARIOS:
                if scenario == "clean":
                    continue
                flows[scenario] = run_sol_scenario(
                    args, config, scenario, batch=False,
                    server_pid=server_pid, warm_up=warm_up)
        except Exception as exc:
            had_errors = True
            remaining = [scenario for scenario, _ in SCENARIOS
                         if scenario not in flows]
            flows.update(write_error_records(
                args, config, remaining,
                "config %s failed: %s" % (config, exc)))
            print("config=%s failed: %s" % (config, exc))
        finally:
            if server_started:
                try:
                    shutdown(args.run, args.work, out_base)
                except Exception as exc:
                    had_errors = True
                    print("config=%s shutdown failed: %s" % (config, exc))
        records[config] = flows
    return (records, had_errors)


def main_run(cmd):
    cmd.run = real_run
    cmd.capture = capture_bazel_output
    cmd.capture_server = capture_bazel_output
    cmd.measure = lambda argv, cwd: measure_with_time(
        argv, cwd, cmd.time_bin)
    cmd.measure_warm = (lambda argv, cwd, server_pid:
                        warm_server.measure(argv, cwd, server_pid))
    configs = list(cmd.config) if cmd.config else list(CONFIG_ORDER)
    unknown = [c for c in configs if c not in CONFIGS]
    if unknown:
        raise ValueError("unknown config(s): %s" % ", ".join(unknown))
    records, had_errors = run_sol_rep(cmd, cmd.rep, configs)
    for config, flows in records.items():
        for scenario, record in flows.items():
            print("flow=%s identical=%s n_sol_actions=%d reason=%s"
                  % (record["flow"], record["identical"],
                     record["n_sol_actions"], record["reason"]))
    return 1 if had_errors else 0


def main_chain(cmd):
    report = run_chain(cmd.log, cmd.execroot, cmd.report, cmd.timeout)
    return 1 if report.get("failed") else 0


def main_summarize(cmd):
    if cmd.lockfile not in ("none", "committed"):
        raise ValueError("invalid lockfile %r: expected none/committed"
                         % (cmd.lockfile,))
    meta = {"sha": cmd.sha, "repeats": cmd.repeats,
            "target_loc": cmd.target_loc, "seed": cmd.seed,
            "bazel_flags": validate_bazel_flags(
                parse_bazel_flags(cmd.bazel_flags)),
            "lockfile": cmd.lockfile}
    platforms = present_platforms(cmd.results)
    configs = [config for platform in platforms
               for config in configs_for_platform(platform)]
    summary = summarize_sol(cmd.results, meta, configs)
    summaries = write_platform_summaries(cmd.results, meta, configs)
    out_dir = os.path.dirname(os.path.abspath(cmd.out))
    for platform, platform_summary in summaries.items():
        write_summary(os.path.join(out_dir, platform + "-sol.json"),
                      platform_summary)
    out_name = os.path.basename(cmd.out)
    primary = None
    for platform, platform_summary in summaries.items():
        if out_name == platform + "-sol.json":
            primary = platform_summary
            break
    if primary is None:
        primary = summaries.get("ios", summary)
    write_summary(cmd.out, primary)
    print_flow_lines(summary)
    return run_exit(summaries, cmd.strict_attribution)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Measure Flutter speed-of-light costs (see module "
                    "docstring).")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="measure one repeat over configs")
    run.add_argument("--tools", required=True)
    run.add_argument("--pristine", required=True)
    run.add_argument("--work", required=True,
                     help="scratch workspace dir (reset per config)")
    run.add_argument("--out-base", required=True,
                     help="output base root; per-config base is <root>/<config>")
    run.add_argument("--results", required=True)
    run.add_argument("--rep", type=int, required=True)
    run.add_argument("--config", action="append", default=[],
                     choices=sorted(CONFIGS),
                     help="repeatable; default is all configs in order")
    run.add_argument("--timeout", type=float, default=1800.0,
                     help="per-action SOL replay timeout in seconds")
    run.add_argument("--min-clean-actions", type=int,
                     default=DEFAULT_MIN_CLEAN_ACTIONS,
                     help="clean builds executing fewer actions fail")
    run.add_argument("--time-bin", default=TIME_BIN,
                     help="accepted for compatibility; ignored: measurement "
                     "is whole-tree rusage on every host")
    run.add_argument("--floor", choices=("on", "off"), default="on",
                     help="also measure the toolchain floor of the mobile "
                     "edit flows (off: the output is the base's)")
    chain = sub.add_parser("chain", help="run one SOL chain (measured child)")
    chain.add_argument("--log", required=True, help="execution log path")
    chain.add_argument("--execroot", required=True,
                       help="build execroot to replay in")
    chain.add_argument("--report", required=True, help="chain report path")
    chain.add_argument("--timeout", type=float, default=1800.0)
    summ = sub.add_parser("summarize",
                          help="write <platform>-sol.json medians")
    summ.add_argument("--results", required=True)
    summ.add_argument("--sha", required=True,
                      help="full rules_flutter commit sha being measured")
    summ.add_argument("--repeats", type=int, required=True)
    summ.add_argument("--target-loc", type=int, required=True)
    summ.add_argument("--seed", type=int, required=True)
    summ.add_argument("--bazel-flags", default="",
                      help="raw whitespace-separated extra Bazel flags "
                      "for this run (recorded in meta)")
    summ.add_argument("--lockfile", default="none",
                      help="none or committed (recorded in meta)")
    summ.add_argument("--strict-attribution", action="store_true",
                      help="exit non-zero when a flow's attribution.ok "
                           "is false (default off)")
    summ.add_argument("--out", required=True,
                      help="platform sol json path")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "run":
        return main_run(args)
    if args.command == "chain":
        return main_chain(args)
    return main_summarize(args)


if __name__ == "__main__":
    sys.exit(main())
