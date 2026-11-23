"""What a hub knows about its lock as a graph: pub's package graph file and
the packages a `build_runner` runner is compiled with.

Both come from the plan (each package's version and planned dependency
names), so neither needs a package archive.
"""

visibility(["//dart/..."])

# A package that defines a builder implements `package:build`'s `Builder`, so
# it depends on one of these.
_BUILDER_API_PACKAGES = ["build", "build_config", "source_gen"]

def package_graph_json(versions, deps):
    """The lock's package graph, in the shape of pub's `.dart_tool/package_graph.json`.

    The user's own packages are not in a lock, so `roots` is empty and no
    package has dev dependencies: a consumer adds the root package from its
    pubspec, as pub does.

    Args:
      versions: Dict of every package of the lock to its version.
      deps: Dict of package name to its planned dependency names.

    Returns:
      The JSON text.
    """
    return json.encode_indent({
        "configVersion": 1,
        "packages": [
            {
                "name": name,
                "version": versions[name],
                "dependencies": sorted(deps.get(name, [])),
                "devDependencies": [],
            }
            for name in sorted(versions.keys())
        ],
        "roots": [],
    }, indent = "  ") + "\n"

def builder_packages(names, deps, labels):
    """The packages of a lock that may define `build_runner` builders.

    A package qualifies when it depends on a package that defines the builder
    API, and its whole dependency closure is in the lock: a package that
    reaches an SDK package (Flutter's) cannot be compiled into the runner,
    and builders run on the Dart VM.

    Args:
      names: Every package of the lock.
      deps: Dict of package name to its planned dependency names.
      labels: Dict of package name to the label of its `build.yaml` file
        group (see `build_yaml_target`).

    Returns:
      Dict of package name to the label of its `build.yaml` file group.
    """
    in_lock = {name: True for name in names}

    # Whether each package's closure stays in the lock, by a worklist over
    # the reverse graph: a package outside the lock spoils its dependents.
    dependents = {}
    for name in names:
        for dep in deps.get(name, []):
            dependents.setdefault(dep, []).append(name)
    spoiled = {}
    queue = [d for d in dependents.keys() if d not in in_lock]

    # Each package joins the queue at most once.
    for _ in range(len(names) + len(queue) + 1):
        if not queue:
            break
        current = queue.pop()
        for parent in dependents.get(current, []):
            if parent not in spoiled:
                spoiled[parent] = True
                queue.append(parent)

    result = {}
    for name in sorted(names):
        if name in spoiled or name not in labels:
            continue
        if not [d for d in deps.get(name, []) if d in _BUILDER_API_PACKAGES]:
            continue
        result[name] = labels[name]
    return result
