"""Checks of a Dart pub workspace's members, for `pub.from_lock(workspace_members = ...)`."""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_document")

visibility(["//dart/..."])

def _label_package(label):
    """Returns the package part of a label string: `//a/b:pubspec.yaml` gives `a/b`."""
    after_repo = label.split("//", 1)[-1]
    return after_repo.split(":", 1)[0]

def _normalize_dir(path):
    """Strips a leading `./` and trailing slashes from a workspace entry."""
    path = str(path)
    for _ in range(len(path)):
        if path.startswith("./"):
            path = path[2:]
    return path.rstrip("/")

def _member_dir(label, root_package):
    """Returns the member's directory relative to the root's, or None when outside it."""
    package = _label_package(label)
    if not root_package:
        return package
    if package.startswith(root_package + "/"):
        return package[len(root_package) + 1:]
    return None

def _resolution_error(label, data):
    """Returns why a member's `resolution:` is wrong, or None."""
    resolution = data.get("resolution")
    if resolution == "workspace":
        return None
    if resolution == None:
        return "member %s: its pubspec.yaml is missing `resolution: workspace`" % label
    return "member %s: its pubspec.yaml sets `resolution: %s`, not `resolution: workspace`" % (label, resolution)

def _layout_error(label, listed, root_package):
    """Returns why a member is not a listed directory of the root, or None."""
    if listed == None:
        return "member %s: the root pubspec.yaml has no `workspace:` list" % label
    member_dir = _member_dir(label, root_package)
    if member_dir == None:
        return "member %s: its pubspec.yaml is outside the root's directory \"%s\"" % (label, root_package)
    if member_dir not in listed:
        return "member %s: its directory \"%s\" is not listed in the root pubspec.yaml `workspace:`" % (label, member_dir)
    return None

def _name_error(label, data, locked_names, declared_names):
    """Returns why a member's `name:` would also resolve to a fetched package, or None."""
    name = data.get("name")
    if name in locked_names:
        return "member %s: its name \"%s\" is also a package in the lock" % (label, name)
    if name in declared_names:
        return "member %s: its name \"%s\" is also declared with pub.package()" % (label, name)
    return None

def pub_workspace_error(root_text, members, root_package = "", locked_names = [], declared_names = []):
    """Checks a pub workspace's members against its root pubspec.

    Args:
        root_text: Text of the root `pubspec.yaml` next to the lock.
        members: Dict of each member's `pubspec.yaml` label string to its text.
            An empty dict means the lock is no workspace lock: nothing is checked.
        root_package: The root's package path in its repository, `""` for the top.
        locked_names: Names of the packages in the lock.
        declared_names: Names declared with `pub.package()`.

    Returns:
        An error string naming one failing member and the reason, or None.
    """
    if not members:
        return None
    root = parse_pubspec_document(root_text, "root pubspec.yaml")
    workspace = root.get("workspace")
    listed = None
    if workspace != None:
        listed = [_normalize_dir(entry) for entry in workspace]
    for label in sorted(members):
        data = parse_pubspec_document(members[label], label)
        error = (_layout_error(label, listed, root_package) or
                 _resolution_error(label, data) or
                 _name_error(label, data, locked_names, declared_names))
        if error:
            return error
    return None

def check_workspaces(ctx, package_tags, lock_tags):
    """Fails when a `workspace_members` lock's members break the pub workspace rules.

    Args:
        ctx: The module extension context, used to read the pubspec files.
        package_tags: The collected `pub.package()` tags.
        lock_tags: The collected `pub.from_lock()` records.
    """
    declared = [pkg.name for pkg in package_tags]
    for lock_tag in lock_tags:
        if not lock_tag.workspace_members:
            continue
        members = {str(label): ctx.read(label) for label in lock_tag.workspace_members}
        root = lock_tag.lock.same_package_label("pubspec.yaml")
        error = pub_workspace_error(ctx.read(root), members, lock_tag.lock.package, lock_tag.packages.keys(), declared)
        if error:
            fail("pub.from_lock \"%s\": %s" % (lock_tag.name, error))
