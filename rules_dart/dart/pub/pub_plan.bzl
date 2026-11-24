"""Public entry point for the pub planner, for a rule set that builds on it.

The `pub` extension plans a lock in three steps, and a module extension of
another rule set (rules_flutter's `flutter.pub`) runs the same three:

1. `plan_pub_graph(ctx, scopes, recorded, shipped)` learns every hosted and
   git package's dependency names: from the lockfile facts, then from
   checked-in plans (`read_pub_plans`), then from the server's listing JSON,
   then from the archive. `scopes` is a list of
   `struct(hosted = {name: struct(version, sha256, url)}, git = {name:
   struct(version, url, resolved_ref, path)})`; `recorded` receives the facts
   to return from the extension (`ctx.extension_metadata(facts = ...)`). It
   returns, per scope, a dict of package name to `{"deps", "sdk"}` plus
   `"archive_url"` for a hosted package.
2. `plan_scope_sccs(names, explicit_deps, hub_names, prefix, deps)` merges the
   dependency cycles of one scope; `members` maps each merged package to its
   repository, `merged` each repository to its members.
3. `own_dep_labels(name, deps, labels)` gives one package repository the
   labels of its own dependencies, from a name-to-label map.

`package_graph_json(versions, deps)` renders the planned graph in the shape of
pub's `.dart_tool/package_graph.json`, for a hub to carry.

Each package repository then gets only its own coordinates, its planned names
and its own labels (`PUB_LOCK_PACKAGE_ATTRS` and `fetch_pub_lock_archive` in
`//dart/pub:pub_lock_package.bzl`), and verifies the planned names against
the fetched pubspec (`spoke_planned_deps_error` in `//dart/pub:pub_scc.bzl`).
The hub is `pub_lock_hub` from `//dart/pub:pub_lock_hub.bzl`, whose `files`
attribute carries what the rule set adds to it.
"""

load("//dart/pub/private:package_graph.bzl", _package_graph_json = "package_graph_json")
load("//dart/pub/private:pub_emit.bzl", _own_dep_labels = "own_dep_labels")
load(
    "//dart/pub/private:pub_plan.bzl",
    _PLAN_FACTS_SCHEMA = "PLAN_FACTS_SCHEMA",
    _hosted_plan_key = "hosted_plan_key",
    _plan_pub_graph = "plan_pub_graph",
    _read_pub_plans = "read_pub_plans",
)
load("//dart/pub/private:scc.bzl", _plan_scope_sccs = "plan_scope_sccs")

visibility("public")

PLAN_FACTS_SCHEMA = _PLAN_FACTS_SCHEMA
hosted_plan_key = _hosted_plan_key
plan_pub_graph = _plan_pub_graph
read_pub_plans = _read_pub_plans
plan_scope_sccs = _plan_scope_sccs
own_dep_labels = _own_dep_labels
package_graph_json = _package_graph_json
