"""Public entry point for pub cycle planning, its facts cache, and its checks.

A rule set with its own pub hub can reuse rules_dart's cycle planner instead
of copying it. This module re-exports the implementation in
`//dart/pub/private`; those private modules stay the single implementation,
and their docstrings describe each function's arguments, result and failure
message. Load from `//dart/pub:pub_scc.bzl`, not from `//dart/pub/private`,
which is not public.

Planner (`compute_sccs`, `package_dep_graph`, `scc_repo_name`):
  `compute_sccs` takes a dict of package name to dependency names and returns
  a list of components, each a sorted list of names, with singletons included.
  It is deterministic: nodes and successors are visited in sorted order and
  the outer list is sorted by each component's first member, so the same graph
  always yields the same list whatever order the caller built the map in.
  `package_dep_graph` builds that graph for one lock scope, dropping edges to
  names outside the scope and self-edges; `scc_repo_name` names the merged
  repository for one component from its sorted members.

Facts (`PARSER_SOURCE_LABELS` and the `parser_*`, `*_fact_key`,
`*_scope_facts`, `fact_deps_error`, `lookup_fact_deps`,
`scratch_pubspec_error`, `read_scope_pubspec` functions):
  Facts are hints, not pins. Their keys carry a fixed schema version plus a
  digest of the pubspec parser's sources, and every fact is verified against
  the package's real pubspec before a repository trusts it. A consumer that
  wants `parser_schema` to match rules_dart's keys must read the bytes of every
  label in `PARSER_SOURCE_LABELS` in that label order and pass them to
  `parser_schema`; another parser, or another order, yields another schema and
  simply misses every existing fact. `split_scope_facts` returns
  `struct(deps, keys, hosted_miss, git_miss)`, `record_scope_facts` fills the
  fact dict to return, and `lookup_fact_deps` reads one key, failing closed on
  a malformed value. `read_scope_pubspec` reads one fetched package's pubspec
  under `scratch_pubspec_error`'s narrowed check.

Verification (`scc_planned_deps_error`, `scc_member_deps_error`,
`spoke_planned_deps_error`, `scc_members_connectivity_error`):
  Each returns None when the real pubspec agrees with the plan, or the
  repository rule's failure message naming the planned and real names and the
  lockfile recovery step when it does not. Call them before generating a
  repository, exactly as the rules in `//dart/pub` do.

This is the API another module extension consumes. It promises the behaviour
described here and in the re-exported functions' docstrings, nothing more.
"""

load("//dart/pub/private:parser_sources.bzl", _PARSER_SOURCE_LABELS = "PARSER_SOURCE_LABELS")
load(
    "//dart/pub/private:pub_scc_facts.bzl",
    _fact_deps_error = "fact_deps_error",
    _git_fact_key = "git_fact_key",
    _hosted_fact_key = "hosted_fact_key",
    _lookup_fact_deps = "lookup_fact_deps",
    _parser_schema = "parser_schema",
    _parser_texts_digest = "parser_texts_digest",
    _read_scope_pubspec = "read_scope_pubspec",
    _record_scope_facts = "record_scope_facts",
    _scratch_pubspec_error = "scratch_pubspec_error",
    _split_scope_facts = "split_scope_facts",
)
load(
    "//dart/pub/private:pub_scc_verify.bzl",
    _scc_member_deps_error = "scc_member_deps_error",
    _scc_members_connectivity_error = "scc_members_connectivity_error",
    _scc_planned_deps_error = "scc_planned_deps_error",
    _spoke_planned_deps_error = "spoke_planned_deps_error",
)
load(
    "//dart/pub/private:scc.bzl",
    _compute_sccs = "compute_sccs",
    _package_dep_graph = "package_dep_graph",
    _scc_repo_name = "scc_repo_name",
)

# Planner: the graph, its components, and the merged repository name.
compute_sccs = _compute_sccs
package_dep_graph = _package_dep_graph
scc_repo_name = _scc_repo_name

# Facts: the parser-bound schema, key building, lookup, split, record, and the
# narrowed scratch read.
PARSER_SOURCE_LABELS = _PARSER_SOURCE_LABELS
parser_schema = _parser_schema
parser_texts_digest = _parser_texts_digest
hosted_fact_key = _hosted_fact_key
git_fact_key = _git_fact_key
fact_deps_error = _fact_deps_error
lookup_fact_deps = _lookup_fact_deps
split_scope_facts = _split_scope_facts
record_scope_facts = _record_scope_facts
scratch_pubspec_error = _scratch_pubspec_error
read_scope_pubspec = _read_scope_pubspec

# Verification: each decision returns None on a match or the fetch failure.
scc_planned_deps_error = _scc_planned_deps_error
scc_member_deps_error = _scc_member_deps_error
spoke_planned_deps_error = _spoke_planned_deps_error
scc_members_connectivity_error = _scc_members_connectivity_error
