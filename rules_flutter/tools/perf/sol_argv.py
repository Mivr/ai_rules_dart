"""Bazel argv builders of the sol driver (split out of sol.py).

Batch and warm commands share one argv shape; the warm form only drops
``--batch`` so it runs on the config's server.
"""

import os

from run_rep import CONFIGS


def startup_options(out_base):
    """Bazel startup options shared by every command on one output base."""
    return ["--output_base=" + out_base]


def command_prefix(batch):
    """``bazel`` argv head: batch commands pass ``--batch``, warm ones do
    not, so they run on the config's server with identical startup options.
    """
    return ["bazel", "--batch"] if batch else ["bazel"]


def info_argv(out_base, key, batch):
    """Full ``bazel info`` argv in either mode."""
    return command_prefix(batch) + startup_options(out_base) + [
        "info", key]


def output_group_of(build_flags):
    """The one group named by an ``--output_groups=<group>`` flag, or None.

    A flag with several groups or ``+`` additions is not a single-group
    build, so it is not a group listing either.
    """
    for flag in build_flags:
        value = flag.partition("--output_groups=")[2]
        if value and "," not in value and not value.startswith("+"):
            return value
    return None


def listing_expr(build_flags):
    """Starlark expression listing what ``bazel build`` writes.

    The DefaultInfo files, unless the flags select one output group: then
    only that group's declared files, as the build produces nothing else.
    """
    group = output_group_of(build_flags)
    if group is None:
        files = "target.files"
    else:
        files = 'providers(target)["OutputGroupInfo"].' + group
    return '"\\n".join([f.path for f in %s.to_list()])' % files


def cquery_argv(out_base, target, build_flags, batch):
    """Full ``bazel cquery`` argv in either mode.

    Lists ``target.files`` (DefaultInfo.files) only, or the one output
    group the build flags select (see ``listing_expr``): ``--output=files``
    would add the ``.bazelrc`` ``test`` aspect output groups, whose
    outputs ``bazel build`` never builds.
    """
    expr = listing_expr(build_flags)
    return (command_prefix(batch) + startup_options(out_base)
            + ["cquery", "--output=starlark", "--starlark:expr=" + expr,
               target] + list(build_flags))


def build_argv(out_base, config, log_path, profile_path, batch):
    """Full ``bazel build`` argv: the warm form drops ``--batch`` only.

    The same target, build flags, execution log, trace profile and
    param-file materialization either way; ``profile_path`` None (the
    unmeasured warm-up build) omits ``--profile``.
    """
    spec = CONFIGS[config]
    argv = (command_prefix(batch) + startup_options(out_base) + ["build"]
            + list(spec["build_flags"])
            + [spec["target"],
               "--execution_log_json_file=" + log_path,
               "--materialize_param_files"])
    if profile_path is not None:
        argv.append("--profile=" + profile_path)
    return argv


def out_base_of(args, config):
    """Per-config output base: no shared server between configs."""
    return os.path.join(args.out_base, config)


def add_clean_replay_arg(run):
    """Adds `--clean-replay` to the `run` sub-command (default `first`)."""
    run.add_argument("--clean-replay", choices=("first", "every"),
                     default="first",
                     help="first: replay a config's clean flow in one "
                     "repeat only (later repeats still build and "
                     "measure it); every: replay it in every repeat")
