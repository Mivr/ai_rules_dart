"""Source labels for the pubspec facts digest.

`READER_SOURCE_LABELS` lists the files whose bytes key the pub extension's
cycle-planning facts (see `parser_schema` in `:pub_scc_facts.bzl`): the `yq`
release, its checksums and the conversion (`yq.bzl`) and the checks and
projection over the decoded data (`pubspec_data.bzl`).

`PARSER_SOURCE_LABELS` lists the sources of the Starlark YAML reader, which
`rules_flutter` still digests for its own facts. A bare `//` label
resolves in this extension's own repository, whatever module name it is
known by. The `parser files` guard test asserts this list matches
the public `yaml_parser.bzl` facade's load closure, which reaches the
implementation in `private/yaml_parser.bzl`, so a new load there cannot be missed
here. It lives here, not in `extensions.bzl`, so that file stays small.
"""

visibility(["//dart/..."])

PARSER_SOURCE_LABELS = [
    Label("//dart/pub:yaml_parser.bzl"),
    Label("//dart/pub/private:yaml_parser.bzl"),
    Label("//dart/pub/private:pin_checks.bzl"),
    Label("//dart/pub/private:yaml_chars.bzl"),
    Label("//dart/pub/private:yaml_subset.bzl"),
    Label("//dart/pub/private:yaml_text.bzl"),
    Label("//dart/pub/private:yaml_escape.bzl"),
    Label("//dart/pub/private:yaml_scalar.bzl"),
    Label("//dart/pub/private:yaml_printable.bzl"),
    Label("//dart/pub/private:yaml_flow.bzl"),
    Label("//dart/pub/private:yaml_flow_scan.bzl"),
    Label("//dart/pub/private:yaml_fold.bzl"),
    Label("//dart/pub/private:yaml_block_scalar.bzl"),
    Label("//dart/pub/private:yaml_block.bzl"),
    Label("//dart/pub/private:yaml_document.bzl"),
    Label("//dart/pub/private:yaml_lock.bzl"),
    Label("//dart/pub/private:yaml_lock_fast.bzl"),
    Label("//dart/pub/private:yaml_sdk_constraint.bzl"),
]

READER_SOURCE_LABELS = [
    Label("//dart/pub/private:yq.bzl"),
    Label("//dart/pub/private:pubspec_data.bzl"),
]
