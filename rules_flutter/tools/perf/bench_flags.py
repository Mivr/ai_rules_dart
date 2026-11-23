#!/usr/bin/env python3
"""Extra Bazel flags for one iOS bench run (A/B experiments).

Workflow_dispatch input ``bazel_flags`` carries Bazel flags separated by
whitespace. They apply to the head workspace only: each accepted token
becomes one ``common <flag>`` line appended to the generated head
workspace's ``.bazelrc``, after generation and before any Bazel command.
Compare mode never gives them to base, and sol mode measures head only.

Only the Python 3 standard library is used.
"""

import argparse
import json
import os
import re
import sys

PLAIN_NAME_RE = re.compile(r"[A-Za-z0-9_]+$")
LABEL_RE = re.compile(
    r"(@[A-Za-z0-9_.\-]+)?//[A-Za-z0-9_./\-]*:[A-Za-z0-9_.\-]+$")
VALUE_RE = re.compile(r"[A-Za-z0-9_@/:.,+=\-]+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

REFUSED_EXACT = frozenset([
    "disk_cache",
    "repository_cache",
    "output_base",
    "output_user_root",
    "install_base",
    "symlink_prefix",
    "profile",
    "generate_json_trace_profile",
    "config",
    "bazelrc",
    "ignore_all_rc_files",
    "lockfile_mode",
    "override_module",
    "override_repository",
    "registry",
    "batch",
    "host_jvm_args",
    "max_idle_secs",
])

REFUSED_PREFIXES = (
    "remote_",
    "experimental_remote",
    "bes_",
    "google_",
    "execution_log",
    "experimental_execution_log",
)

FORBIDDEN_CHARS = frozenset(list(" \t\n\r\x0b\x0c'\"$`;|&<>\\#") + ["`"])


def parse_bazel_flags(text):
    """Split raw workflow input into tokens (empty input gives [])."""
    if text is None or not str(text).strip():
        return []
    return str(text).split()


def split_token(token):
    """Split ``--name`` or ``--name=value`` into (name, value-or-None)."""
    if not token.startswith("--") or len(token) <= 2:
        return (None, None)
    body = token[2:]
    if "=" in body:
        name, _, value = body.partition("=")
        return (name, value)
    return (body, None)


def is_label(name):
    """Whether name is a Starlark flag label (@repo//pkg:name)."""
    return LABEL_RE.match(name) is not None


def refused_name(name):
    """Whether a plain option name is refused (exact or prefix)."""
    if name in REFUSED_EXACT:
        return True
    for prefix in REFUSED_PREFIXES:
        if name.startswith(prefix):
            return True
    return False


def refused_option(name):
    """Refused directly or in --no<name> boolean-negation form."""
    if is_label(name):
        return False
    if refused_name(name):
        return True
    if name.startswith("no") and len(name) > 2:
        return refused_name(name[2:])
    return False


def check_token(token):
    """Validate one token; returns None when accepted, else a reason."""
    for char in token:
        if char in FORBIDDEN_CHARS or CONTROL_RE.match(char):
            return "forbidden character"
    if not token.startswith("--") or len(token) <= 2:
        return "must be --<name> or --<name>=<value>"
    name, value = split_token(token)
    if not name:
        return "must be --<name> or --<name>=<value>"
    if is_label(name):
        pass
    elif PLAIN_NAME_RE.match(name) is None:
        return "bad option name %r" % name
    if refused_option(name):
        return "refused option %r" % name
    if value is not None:
        if not value:
            return "empty value"
        if VALUE_RE.match(value) is None:
            return "bad value in %r" % token
        if "=" in name:
            return "bad option name %r" % name
    return None


def validate_bazel_flags(tokens):
    """Validate tokens; raises ValueError naming the first bad token."""
    for token in tokens:
        reason = check_token(token)
        if reason is not None:
            raise ValueError(
                "invalid bazel_flags token %r: %s" % (token, reason))
    return list(tokens)


def append_flags(workspace, tokens):
    """Append ``common <flag>`` lines; empty flags leave the file alone."""
    validated = validate_bazel_flags(list(tokens))
    if not validated:
        return 0
    path = os.path.join(workspace, ".bazelrc")
    with open(path, "a", encoding="utf-8", newline="\n") as fh:
        for token in validated:
            fh.write("common %s\n" % token)
    return len(validated)


def is_worker_spawn(spawn):
    """Whether the log marks this spawn as run in a persistent worker."""
    runner = spawn.get("runner") or ""
    return "worker" in str(runner).lower()


def worker_steps(spawns):
    """{mnemonic: count} of spawns Bazel ran in a persistent worker."""
    counts = {}
    for spawn in spawns:
        if is_worker_spawn(spawn):
            mnemonic = spawn.get("mnemonic", "")
            counts[mnemonic] = counts.get(mnemonic, 0) + 1
    return counts


def main(argv=None):
    """Validate ``--flags``; optionally append to a workspace's .bazelrc."""
    parser = argparse.ArgumentParser(
        description="Validate iOS bench bazel_flags.")
    parser.add_argument("--flags", default="",
                        help="raw whitespace-separated Bazel flags")
    parser.add_argument("--workspace", default="",
                        help="generated workspace to append validated "
                        "flags to (its .bazelrc)")
    parser.add_argument("--json-out", default="",
                        help="write the validated token list as JSON")
    args = parser.parse_args(argv)
    try:
        tokens = validate_bazel_flags(parse_bazel_flags(args.flags))
    except ValueError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    if args.workspace:
        try:
            append_flags(args.workspace, tokens)
        except (OSError, ValueError) as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 1
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8",
                  newline="\n") as fh:
            fh.write(json.dumps(tokens) + "\n")
    else:
        print(json.dumps(tokens))
    return 0


if __name__ == "__main__":
    sys.exit(main())
