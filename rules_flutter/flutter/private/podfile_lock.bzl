"""CocoaPods `Podfile.lock` reader and validator for rules_flutter.

Reads the evaluated CocoaPods lockfile committed by Flutter iOS/macOS apps
to discover plugin native pod dependencies and versions without running Ruby.
"""

load(
    "//flutter/private:podfile_lock_scan.bzl",
    "count_indent",
    "has_flow_or_anchor",
    "has_indent_tab",
    "make_refusal",
    "parse_mapping_line",
    "parse_pods_dep",
    "parse_pods_entry",
    "starts_with_flow_or_anchor",
    "unquote",
)

visibility(["//flutter/..."])

_ALLOWED_TOP_LEVEL = {
    "CHECKOUT OPTIONS": True,
    "COCOAPODS": True,
    "DEPENDENCIES": True,
    "EXTERNAL SOURCES": True,
    "PODFILE CHECKSUM": True,
    "PODS": True,
    "SPEC CHECKSUMS": True,
    "SPEC REPOS": True,
}

_CHECKOUT_KINDS = {
    "git": True,
    "hg": True,
    "http": True,
    "svn": True,
}

_TAB_DETAIL = "an indentation tab is not part of the Podfile.lock YAML subset rules_flutter reads"
_FLOW_DETAIL = "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads"

def _make_failure(error):
    """Build a failure struct with empty maps."""
    return struct(
        ok = False,
        error = error,
        pods = {},
        plugin_pods = {},
        spec_repos = {},
        checksums = {},
        checkout = {},
    )

def _handle_pods(state, stripped, indent, line_num, label):
    """Handle a line inside the PODS section."""
    if indent == 2:
        entry = parse_pods_entry(stripped)
        if not entry.ok:
            return make_refusal(
                label,
                line_num,
                '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = stripped),
            )
        if entry.name in state.pods:
            return make_refusal(
                label,
                line_num,
                'PODS lists "{pod}" twice'.format(pod = entry.name),
            )
        state.pods[entry.name] = struct(version = entry.version, line = line_num)
        state.pod_deps[entry.name] = []
        state.current["pod"] = entry.name
        state.current["has_colon"] = entry.has_colon
        state.current["entry_line"] = line_num
        state.current["entry_text"] = stripped
        return ""

    if indent > 2 and state.current["pod"] and not state.current["has_colon"]:
        return make_refusal(
            label,
            state.current["entry_line"],
            '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = state.current["entry_text"]),
        )

    if indent == 4 and state.current["pod"]:
        dep = parse_pods_dep(stripped)
        if not dep.ok:
            return make_refusal(
                label,
                line_num,
                '"{text}" is not a "<name> (<requirement>)" PODS dependency'.format(text = stripped),
            )
        state.pod_deps[state.current["pod"]].append(
            struct(name = dep.name, requirement = dep.requirement),
        )
        return ""

    if not state.current["pod"] or stripped.endswith(":") or indent < 2:
        return make_refusal(
            label,
            line_num,
            '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = stripped),
        )
    return make_refusal(
        label,
        line_num,
        '"{text}" is not a "<name> (<requirement>)" PODS dependency'.format(text = stripped),
    )

def _handle_spec_repos(state, stripped, indent):
    """Handle a line inside the SPEC REPOS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["repo"] = kv.key
    elif indent > 2:
        pod = stripped[2:].strip() if stripped.startswith("- ") else stripped
        pod = unquote(pod)
        repo = state.current["repo"]
        if repo and pod:
            state.spec_repos[pod] = repo

def _plugin_pkg_from_path(path):
    """Extract pub package name from `.symlinks/plugins/<pkg>/<ios|darwin|macos>`, or `""`."""
    prefix = ".symlinks/plugins/"
    if not path.startswith(prefix):
        return ""
    parts = path[len(prefix):].split("/")
    if len(parts) == 2 and parts[1] in ("ios", "darwin", "macos") and parts[0] not in ("", ".", ".."):
        return parts[0]
    return ""

def _handle_external_sources(state, stripped, indent):
    """Handle a line inside the EXTERNAL SOURCES section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["ext_pod"] = kv.key
        return
    if indent <= 2 or not state.current["ext_pod"]:
        return
    pod = state.current["ext_pod"]
    kv = parse_mapping_line(stripped)
    if not kv.is_symbol:
        return
    if kv.kind == "path":
        pkg = _plugin_pkg_from_path(kv.value)
        if pkg:
            state.plugin_pods[pod] = pkg
    elif kv.kind in _CHECKOUT_KINDS and pod not in state.checkout:
        state.checkout[pod] = kv.kind

def _handle_checkout_options(state, stripped, indent):
    """Handle a line inside the CHECKOUT OPTIONS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["checkout_pod"] = kv.key
    elif indent > 2:
        pod = state.current["checkout_pod"]
        if not pod:
            return
        kv = parse_mapping_line(stripped)
        if kv.is_symbol and kv.kind in _CHECKOUT_KINDS and pod not in state.checkout:
            state.checkout[pod] = kv.kind

def _handle_spec_checksums(state, stripped, indent):
    """Handle a line inside the SPEC CHECKSUMS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        if kv.has_kv and kv.key and kv.value:
            state.checksums[kv.key] = kv.value

def _handle_top_level(state, stripped, line_num, label):
    """Handle a top-level section header."""
    kv = parse_mapping_line(stripped)
    top_key = kv.key if kv.has_kv else stripped
    if not kv.has_kv or top_key not in _ALLOWED_TOP_LEVEL:
        return make_refusal(
            label,
            line_num,
            '"{key}" is not a Podfile.lock top-level key rules_flutter reads'.format(key = top_key),
        )
    state.current["section"] = top_key
    state.current["pod"] = ""
    state.current["has_colon"] = False
    state.current["entry_line"] = 0
    state.current["entry_text"] = ""
    state.current["repo"] = ""
    state.current["ext_pod"] = ""
    state.current["checkout_pod"] = ""
    return ""

def _dispatch_section(state, stripped, indent, line_num, label):
    """Dispatch a content line to the active section handler."""
    section = state.current["section"]
    if section == "PODS":
        return _handle_pods(state, stripped, indent, line_num, label)
    if section == "SPEC REPOS":
        _handle_spec_repos(state, stripped, indent)
        return ""
    if section == "EXTERNAL SOURCES":
        _handle_external_sources(state, stripped, indent)
        return ""
    if section == "CHECKOUT OPTIONS":
        _handle_checkout_options(state, stripped, indent)
        return ""
    if section == "SPEC CHECKSUMS":
        _handle_spec_checksums(state, stripped, indent)
        return ""
    if section in ("DEPENDENCIES", "PODFILE CHECKSUM", "COCOAPODS"):
        return ""
    kv = parse_mapping_line(stripped)
    return make_refusal(
        label,
        line_num,
        '"{key}" is not a Podfile.lock top-level key rules_flutter reads'.format(key = kv.key),
    )

def _scan_line(state, raw_line, line_num, label):
    """Process one raw line of `Podfile.lock`, returning `""` or refusal text."""
    if raw_line.endswith("\r"):
        raw_line = raw_line[:-1]
    if has_indent_tab(raw_line):
        return make_refusal(label, line_num, _TAB_DETAIL)
    stripped = raw_line.strip()
    if not stripped:
        return ""
    if starts_with_flow_or_anchor(stripped):
        return make_refusal(label, line_num, _FLOW_DETAIL)
    indent = count_indent(raw_line)
    is_pods_list_item = (
        state.current["section"] == "PODS" and
        (stripped == "-" or stripped.startswith("- ") or stripped.startswith("-\t"))
    )
    if indent == 0 and not is_pods_list_item:
        err = _handle_top_level(state, stripped, line_num, label)
        if err:
            return err
        if has_flow_or_anchor(stripped):
            return make_refusal(label, line_num, _FLOW_DETAIL)
        return ""
    if has_flow_or_anchor(stripped):
        return make_refusal(label, line_num, _FLOW_DETAIL)
    return _dispatch_section(state, stripped, indent, line_num, label)

def _build_pods_map(state):
    """Convert state pods and deps into final structs."""
    pods = {}
    for name, entry in state.pods.items():
        pods[name] = struct(
            version = entry.version,
            deps = list(state.pod_deps.get(name, [])),
            line = entry.line,
        )
    return pods

def read_podfile_lock(text, label):
    """Parse CocoaPods `Podfile.lock` text into structured pod data.

    Args:
        text: The file content string.
        label: The file label string, for error reporting.

    Returns:
        `struct(ok, error, pods, plugin_pods, spec_repos, checksums, checkout)`:
        on success, `ok` is True and `error` is `""`. On failure, `ok` is False,
        `error` holds the refusal message, and all maps are empty.
    """
    lines = text.split("\n")
    state = struct(
        pods = {},
        pod_deps = {},
        plugin_pods = {},
        spec_repos = {},
        checksums = {},
        checkout = {},
        current = {
            "section": "",
            "pod": "",
            "has_colon": False,
            "entry_line": 0,
            "entry_text": "",
            "repo": "",
            "ext_pod": "",
            "checkout_pod": "",
        },
    )

    for line_idx in range(len(lines)):
        err = _scan_line(state, lines[line_idx], line_idx + 1, label)
        if err:
            return _make_failure(err)

    return struct(
        ok = True,
        error = "",
        pods = _build_pods_map(state),
        plugin_pods = dict(state.plugin_pods),
        spec_repos = dict(state.spec_repos),
        checksums = dict(state.checksums),
        checkout = dict(state.checkout),
    )
