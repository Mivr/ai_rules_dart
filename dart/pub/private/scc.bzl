"""Strongly connected components over a pubspec dependency graph.

`pub.from_lock()` generates one `dart_library` per hosted package, with `deps`
taken from each package's pubspec. When two packages depend on each other
(`dio` and `dio_web_adapter` do), those libraries form a cycle in the Bazel
target graph and analysis fails — before any action runs.

The fix merges every dependency cycle into one `dart_library` that carries all
of the cycle's packages. Finding the cycles is Tarjan's algorithm over the
graph the extension builds from the lock's packages and their pubspecs'
`dependencies:` sections (see `//dart/pub:extensions.bzl`). This module holds
that one pure function so it can be unit tested without downloading anything.
"""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps")

def compute_sccs(dep_map):
    """Computes the strongly connected components of a dependency graph.

    Iterative Tarjan's algorithm, so deep graphs cannot overflow a call stack
    Starlark does not even have. Deterministic: nodes are visited in sorted
    order and successors in sorted order, so the same graph always yields the
    same components whatever order the caller built the map in.

    Args:
      dep_map: Dict of package name to the names it depends on. Edges naming
        a package the map does not hold are ignored — a dependency on a
        package outside the lock (an SDK package, an explicit
        `pub.package()`) cannot be part of a lock-internal cycle. A
        self-edge is ignored for the same reason it is dropped from generated
        deps: a target depending on itself is a cycle of one, and merging it
        with itself changes nothing.

    Returns:
      List of components, each a sorted list of package names. The outer list
      is sorted by each component's first name. Singletons included: the
      caller keeps them as one-package spokes and merges only the components
      with more than one member.
    """
    names = sorted(dep_map.keys())
    in_graph = {name: True for name in names}

    # Successors, filtered and sorted: only edges inside the graph, in a
    # fixed order, so iteration order cannot leak into the result.
    successors = {
        name: sorted([
            dep
            for dep in dep_map[name]
            if dep in in_graph and dep != name
        ])
        for name in names
    }

    index_of = {}
    lowlink = {}
    on_stack = {}
    stack = []
    counter = [0]
    result = []

    # Step budget for the iterative walk: each iteration pushes a node, pops
    # one, or advances past one edge, so `2 * nodes + edges + 1` always
    # suffices. (`while` does not exist in Bazel's Starlark.)
    total_edges = 0
    for name in names:
        total_edges += len(successors[name])

    for root in names:
        if root in index_of:
            continue
        work = [(root, 0)]
        for _ in range(2 * len(names) + total_edges + 1):
            if not work:
                break
            top = work[-1]
            node = top[0]
            child_pos = top[1]
            if child_pos == 0 and node not in index_of:
                index_of[node] = counter[0]
                lowlink[node] = counter[0]
                counter[0] += 1
                stack.append(node)
                on_stack[node] = True
            deps = successors[node]
            if child_pos < len(deps):
                work[-1] = (node, child_pos + 1)
                child = deps[child_pos]
                if child not in index_of:
                    work.append((child, 0))
                elif on_stack.get(child, False):
                    if index_of[child] < lowlink[node]:
                        lowlink[node] = index_of[child]
            else:
                work.pop()
                if work:
                    parent = work[-1][0]
                    if lowlink[node] < lowlink[parent]:
                        lowlink[parent] = lowlink[node]
                if lowlink[node] == index_of[node]:
                    component = []
                    for _ in range(len(stack)):
                        member = stack.pop()
                        on_stack[member] = False
                        component.append(member)
                        if member == node:
                            break
                    result.append(sorted(component))

    order = {}
    for component in result:
        first = component[0]
        order[first] = component
    return [order[key] for key in sorted(order.keys())]

def normalize_pub_dep(dep, hub_names, spoke_prefixes):
    """Normalizes one user-declared `pub.package()` dep to a package name.

    Lock packages name each other by package name (their pubspecs do), but
    an explicit `pub.package()` names repositories: a bare spoke
    (`dart_pub__foo`), a spoke label (`@dart_pub__foo//:foo`), or a hub alias
    (`@my_hub//:foo`). All three mean package `foo` for cycle purposes. A
    label on an unknown repository names no lock package, so it contributes
    no edge.

    Args:
      dep: The user-declared dep string.
      hub_names: All hub repository names in scope.
      spoke_prefixes: Spoke repo name prefixes in scope (`dart_pub` for the
        shared scope, hub names for isolated ones).

    Returns:
      The package name, or "" when the dep names no lock package.
    """
    label = dep[1:] if dep.startswith("@") else dep
    if "//" in label:
        repo, _, target = label.partition("//")
        name = target[1:] if target.startswith(":") else target.split("/")[0]
        if repo in hub_names:
            return name
        for prefix in spoke_prefixes:
            if repo == prefix + "__" + name:
                return name
        return ""
    if dep.startswith("@"):
        return ""
    for prefix in spoke_prefixes:
        if dep.startswith(prefix + "__"):
            return dep[len(prefix) + 2:]
    return dep

def pubspec_dep_graph(package_pubspecs, explicit_deps, scope_names, hub_names, spoke_prefixes):
    """Builds the package dependency graph of one lock scope.

    Pure given the pubspec contents: the extension downloads each hosted
    package once and calls this to plan the merges, so the shape is unit
    tested without any download.

    Args:
      package_pubspecs: Dict of hosted package name to its `pubspec.yaml`
        contents.
      explicit_deps: Dict of explicit `pub.package()` name to its
        user-declared deps.
      scope_names: Every package name in scope (hosted plus explicit).
      hub_names: All hub repository names in scope.
      spoke_prefixes: Spoke repo name prefixes in scope.

    Returns:
      Dict of package name to its sorted in-scope dependency names, with
      self-edges dropped.
    """
    in_scope = {name: True for name in scope_names}
    graph = {}
    for name, content in package_pubspecs.items():
        deps = parse_pubspec_deps(content)
        graph[name] = sorted([d for d in deps if d in in_scope and d != name])
    for name, user_deps in explicit_deps.items():
        normalized = [
            normalize_pub_dep(d, hub_names, spoke_prefixes)
            for d in user_deps
        ]
        graph[name] = sorted([d for d in normalized if d in in_scope and d != name])
    return graph

def scc_repo_name(spoke_prefix, members):
    """Names the merged repository holding one dependency cycle.

    Deterministic in the sorted member names, so every hub aliasing the
    cycle, and every spoke depending into it, names the same repository.

    Args:
      spoke_prefix: The scope's spoke repo name prefix.
      members: The cycle's sorted member package names. Must be non-empty.

    Returns:
      The merged repository name.
    """
    return spoke_prefix + "__scc__" + "__".join(members)

def rewrite_vanished_spoke(dep, vanished):
    """Rewrites a dep on a merged-away spoke to its merged repository.

    Args:
      dep: A user-declared dep string (a bare repo name or a label).
      vanished: Dict of vanished spoke repo name to merged repo name.

    Returns:
      The dep naming the merged repository, or `dep` unchanged.
    """
    bare = dep[1:] if dep.startswith("@") else dep
    repo, sep, rest = bare.partition("//")
    if repo in vanished:
        fixed = vanished[repo] + (sep + rest if sep else "")
        return ("@" if dep.startswith("@") else "") + fixed
    return dep
