"""Parser source labels for the pubspec facts digest.

Lists the pubspec parser sources whose bytes key the cycle-planning
facts (see `parser_schema` in `:pub_scc_facts.bzl`). A bare `//` label
resolves in this extension's own repository, whatever module name it is
known by. The `parser files` guard test asserts this list matches
`yaml_parser.bzl`'s load closure, so a new load there cannot be missed
here. It lives here, not in `extensions.bzl`, so that file stays small.
"""

PARSER_SOURCE_LABELS = [
    Label("//dart/pub:yaml_parser.bzl"),
    Label("//dart/pub/private:yaml_chars.bzl"),
    Label("//dart/pub/private:yaml_subset.bzl"),
    Label("//dart/pub/private:yaml_text.bzl"),
    Label("//dart/pub/private:yaml_escape.bzl"),
    Label("//dart/pub/private:yaml_scalar.bzl"),
    Label("//dart/pub/private:yaml_flow.bzl"),
    Label("//dart/pub/private:yaml_flow_scan.bzl"),
    Label("//dart/pub/private:yaml_fold.bzl"),
    Label("//dart/pub/private:yaml_block_scalar.bzl"),
    Label("//dart/pub/private:yaml_block.bzl"),
    Label("//dart/pub/private:yaml_document.bzl"),
    Label("//dart/pub/private:yaml_lock.bzl"),
    Label("//dart/pub/private:yaml_lock_fast.bzl"),
]
