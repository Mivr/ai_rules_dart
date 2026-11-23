"""Checks of a Dart pub workspace's members, for `pub.from_lock(workspace_members = ...)`."""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_document")

visibility(["//dart/..."])

def _segments(path):
    """Splits a path into segments, dropping `.` and empty ones."""
    return [seg for seg in str(path).split("/") if seg and seg != "."]

def _label_dir(label):
    """Returns a pubspec label's directory: its package joined with its name's directory part."""
    package, _, name = label.split("//", 1)[-1].partition(":")
    return "/".join(_segments(package) + _segments(name.rpartition("/")[0]))

def _member_dir(label, root_dir):
    """Returns the member's directory relative to the root's, or None when outside it."""
    package = _segments(_label_dir(label))
    root = _segments(root_dir)
    if package[:len(root)] != root:
        return None
    return "/".join(package[len(root):])

def _segment_matches(pattern, text):
    """Returns whether `*` and `?` pattern matches one path segment."""
    size = len(text)
    states = [0]
    for char in pattern.elems():
        if not states:
            return False
        if char == "*":
            states = range(min(states), size + 1)
        elif char == "?":
            states = [i + 1 for i in states if i < size]
        else:
            states = [i + 1 for i in states if i < size and text[i] == char]
    return size in states

def _skip_globstars(pattern, states):
    """Adds the pattern positions reachable by letting `**` segments match nothing."""
    reach = {}
    for start in states:
        pos = start
        reach[pos] = True
        for _ in range(len(pattern)):
            if pos < len(pattern) and pattern[pos] == "**":
                pos += 1
                reach[pos] = True
    return reach.keys()

def _path_matches(pattern, path):
    """Returns whether a segment pattern (`**` = any number of segments) matches a segment path."""
    states = _skip_globstars(pattern, [0])
    for seg in path:
        reached = []
        for pos in states:
            if pos == len(pattern):
                continue
            if pattern[pos] == "**":
                reached.append(pos)
            elif _segment_matches(pattern[pos], seg):
                reached.append(pos + 1)
        states = _skip_globstars(pattern, reached)
    return len(pattern) in states

def _unsupported_error(entry, source):
    """Returns the message for a `workspace:` entry with a glob form the check cannot judge."""
    return ("the `workspace:` entry \"%s\" of %s uses `[` or `{`, a glob form that is not supported: " +
            "the check cannot judge it") % (entry, source)

def _entry_patterns(data, base, source):
    """Returns (patterns, error) for a pubspec's `workspace:` entries, relative to `base` segments."""
    entries = data.get("workspace")
    if entries == None:
        return [], None
    if type(entries) != "list":
        return None, "the `workspace:` of %s is not a list" % source
    patterns = []
    for entry in entries:
        if "[" in str(entry) or "{" in str(entry):
            return None, _unsupported_error(entry, source)
        patterns.append(base + _segments(entry))
    return patterns, None

def _listed(patterns, path):
    """Returns whether any pattern matches the member path."""
    return any([_path_matches(pattern, path) for pattern in patterns])

def _workspace_patterns(root_data, parsed, root_dir):
    """Returns (patterns, error): the root's entries plus those of listed members, recursively."""
    patterns, error = _entry_patterns(root_data, [], "the root pubspec.yaml")
    if error:
        return None, error
    done = {}
    for _ in range(len(parsed) + 1):
        grew = False
        for label in sorted(parsed):
            member_dir = _member_dir(label, root_dir)
            if label in done or member_dir == None or not _listed(patterns, _segments(member_dir)):
                continue
            done[label] = True
            grew = True
            more, error = _entry_patterns(parsed[label], _segments(member_dir), label)
            if error:
                return None, error
            patterns += more
        if not grew:
            break
    return patterns, None

def _resolution_error(label, data):
    """Returns why a member's `resolution:` is wrong, or None."""
    resolution = data.get("resolution")
    if resolution == "workspace":
        return None
    if resolution == None:
        return "member %s: its pubspec.yaml is missing `resolution: workspace`" % label
    return "member %s: its pubspec.yaml sets `resolution: %s`, not `resolution: workspace`" % (label, resolution)

def _layout_error(label, patterns, root_dir):
    """Returns why a member is not a listed directory of the root, or None."""
    if patterns == None:
        return "member %s: the root pubspec.yaml has no `workspace:` list" % label
    member_dir = _member_dir(label, root_dir)
    if member_dir == None:
        return "member %s: its pubspec.yaml is outside the root's directory \"%s\"" % (label, root_dir)
    if not _listed(patterns, _segments(member_dir)):
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

def _with_overrides(text, overrides_text, label):
    """Parses a pubspec; the top-level keys of its `pubspec_overrides.yaml` replace its own."""
    data = dict(parse_pubspec_document(text, label))
    if overrides_text != None:
        data.update(parse_pubspec_document(overrides_text, "pubspec_overrides.yaml of " + label))
    return data

def pub_workspace_error(
        root_text,
        members,
        root_package = "",
        locked_names = [],
        declared_names = [],
        root_overrides = None,
        member_overrides = {}):
    """Checks a pub workspace's members against its root pubspec.

    Args:
        root_text: Text of the root `pubspec.yaml` next to the lock.
        members: Dict of each member's `pubspec.yaml` label string to its text.
            An empty dict means the lock is no workspace lock: nothing is checked.
        root_package: The root's directory in its repository, `""` for the top.
        locked_names: Names of the packages in the lock.
        declared_names: Names declared with `pub.package()`.
        root_overrides: Text of the root's `pubspec_overrides.yaml`, or None.
        member_overrides: Dict of a member's label string to the text of its `pubspec_overrides.yaml`.

    Returns:
        An error string naming one failing member and the reason, or None.
    """
    if not members:
        return None
    root = _with_overrides(root_text, root_overrides, "root pubspec.yaml")
    parsed = {label: _with_overrides(members[label], member_overrides.get(label), label) for label in members}
    patterns = None
    if root.get("workspace") != None:
        patterns, error = _workspace_patterns(root, parsed, root_package)
        if error:
            return error
    for label in sorted(members):
        data = parsed[label]
        error = (_layout_error(label, patterns, root_package) or
                 _resolution_error(label, data) or
                 _name_error(label, data, locked_names, declared_names))
        if error:
            return error
    return None

def pub_workspace_root(lock, read, exists):
    """Finds the root pubspec of a lock: the `pubspec.yaml` in the lock file's own directory.

    Args:
        lock: The lock file's Label.
        read: Function returning the text of a Label.
        exists: Function returning whether a Label's file exists.

    Returns:
        A struct with `text`, `overrides` (text or None) and `dir` (the root directory).
    """
    prefix = lock.name.rpartition("/")[0]
    prefix = prefix + "/" if prefix else ""
    overrides = lock.same_package_label(prefix + "pubspec_overrides.yaml")
    return struct(
        text = read(lock.same_package_label(prefix + "pubspec.yaml")),
        overrides = read(overrides) if exists(overrides) else None,
        dir = _label_dir(str(lock)),
    )

def _read_member_overrides(ctx, label):
    """Returns the text of the `pubspec_overrides.yaml` beside a member's pubspec, or None."""
    prefix = label.name.rpartition("/")[0]
    overrides = label.same_package_label((prefix + "/" if prefix else "") + "pubspec_overrides.yaml")
    return ctx.read(overrides) if ctx.path(overrides).exists else None

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
        overrides = {str(label): _read_member_overrides(ctx, label) for label in lock_tag.workspace_members}
        root = pub_workspace_root(lock_tag.lock, ctx.read, lambda label: ctx.path(label).exists)
        error = pub_workspace_error(
            root.text,
            members,
            root.dir,
            lock_tag.packages.keys(),
            declared,
            root.overrides,
            {label: text for label, text in overrides.items() if text != None},
        )
        if error:
            fail("pub.from_lock \"%s\": %s" % (lock_tag.name, error))
