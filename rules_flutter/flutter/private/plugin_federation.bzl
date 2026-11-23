"""Federated plugin resolution for platform registrants.

Resolves federated plugin implementations according to Flutter's
resolvePlatformImplementation rules per target platform.
"""

visibility(["//flutter/..."])

def _dart_plugin_entry(plugin, info):
    """Builds the registrant entry for one plugin's Dart class info.

    Args:
        plugin: Plugin struct.
        info: Platform info dict.

    Returns:
        A struct with package, dart_plugin_class, and dart_file_name.
    """
    return struct(
        package = plugin.name,
        dart_plugin_class = info.get("dartPluginClass", ""),
        dart_file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart")),
    )

def collect_platform_dart_plugins(plugins, target_platform):
    """Collects `dartPluginClass` entries for one platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.

    Returns:
        List of dart plugin entry structs.
    """
    dart_plugins = []
    for plugin in plugins:
        info = plugin.platforms.get(target_platform, {})
        if not info:
            continue
        entry = _dart_plugin_entry(plugin, info)
        if entry.dart_plugin_class:
            dart_plugins.append(entry)
    return dart_plugins

def collect_legacy_dart_plugins(plugins):
    """Collects entries by first platform with a `dartPluginClass`.

    Args:
        plugins: List of plugin structs.

    Returns:
        List of dart plugin entry structs.
    """
    dart_plugins = []
    for plugin in plugins:
        for _platform, info in plugin.platforms.items():
            entry = _dart_plugin_entry(plugin, info)
            if entry.dart_plugin_class:
                dart_plugins.append(entry)
                break
    return dart_plugins

def _platform_info(plugin, platform):
    """Return the platform dict for plugin on platform, or {}.

    Args:
        plugin: Plugin struct.
        platform: Target platform string.

    Returns:
        Platform dict or empty dict.
    """
    platforms = getattr(plugin, "platforms", None)
    if type(platforms) != "dict":
        return {}
    info = platforms.get(platform, {})
    return info if type(info) == "dict" else {}

def _find_plugin(plugins, name):
    """Finds a plugin by package name in plugins, or None."""
    for p in plugins:
        if p.name == name:
            return p
    return None

def _is_inline_umbrella(plugin, target_platform):
    """Checks whether an umbrella plugin implements itself inline on target_platform."""
    info = _platform_info(plugin, target_platform)
    for k in info:
        if k != "default_package":
            return True
    return False

def _collect_candidates(plugins, target_platform, umbrella_name, umbrella_plugin, default_pkg):
    """Collects candidate implementations for umbrella_name on target_platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.
        umbrella_name: The umbrella package name being implemented.
        umbrella_plugin: The umbrella plugin struct, or None.
        default_pkg: The default implementation package name.

    Returns:
        List of candidate plugin structs that implement umbrella_name.
    """
    candidates = []
    if umbrella_plugin and _is_inline_umbrella(umbrella_plugin, target_platform):
        candidates.append(umbrella_plugin)

    for p in plugins:
        if p.name == umbrella_name:
            continue
        info = _platform_info(p, target_platform)
        if not info:
            continue
        impl = getattr(p, "implements", "")
        if impl == umbrella_name or (default_pkg and p.name == default_pkg):
            if p not in candidates:
                candidates.append(p)
    return candidates

def _fail_multiple_implementations(umbrella_name, target_platform, names, default_pkg):
    """Fails with an error message naming conflicting implementations.

    Args:
        umbrella_name: The umbrella package name being implemented.
        target_platform: Target platform string.
        names: Comma-separated names of conflicting candidate packages.
        default_pkg: The default implementation package name, or empty string.
    """
    if default_pkg:
        fail('flutter plugin registrant: "%s" has more than one implementation for %s (%s). Depend on one, or on the default "%s" only.' % (
            umbrella_name,
            target_platform,
            names,
            default_pkg,
        ))
    fail('flutter plugin registrant: "%s" has more than one implementation for %s (%s). Depend on one only.' % (
        umbrella_name,
        target_platform,
        names,
    ))

def _resolve_one_umbrella(umbrella_name, plugins, target_platform):
    """Resolves implementation for a single umbrella according to Flutter rules.

    Args:
        umbrella_name: The umbrella package name being implemented.
        plugins: List of all plugin structs.
        target_platform: Target platform string.

    Returns:
        A struct(chosen, default_pkg, candidates) if resolved, or None.
    """
    umbrella_plugin = _find_plugin(plugins, umbrella_name)
    default_pkg = ""
    if umbrella_plugin:
        default_pkg = _platform_info(umbrella_plugin, target_platform).get("default_package", "")

    candidates = _collect_candidates(plugins, target_platform, umbrella_name, umbrella_plugin, default_pkg)
    if not candidates:
        return None

    # 1. Exactly one candidate implementation: it is registered.
    if len(candidates) == 1:
        return struct(chosen = candidates[0], default_pkg = default_pkg, candidates = candidates)

    # 2. Else the one candidate that is direct: it is registered, and the other
    # candidates and the default are not. An umbrella that implements itself
    # inline counts as a candidate, and yields to a direct alternative (S3).
    alt_direct = [c for c in candidates if c.name != umbrella_name and getattr(c, "direct", False)]
    if len(alt_direct) == 1:
        return struct(chosen = alt_direct[0], default_pkg = default_pkg, candidates = candidates)
    if len(alt_direct) >= 2:
        direct_names = ", ".join(sorted([c.name for c in alt_direct]))
        _fail_multiple_implementations(umbrella_name, target_platform, direct_names, default_pkg)

    if umbrella_plugin and getattr(umbrella_plugin, "direct", False) and umbrella_plugin in candidates:
        return struct(chosen = umbrella_plugin, default_pkg = default_pkg, candidates = candidates)

    # 3. Else the endorsed default_package: it is registered when it is one of
    # the candidates. A default that is not among them is never invented.
    if default_pkg:
        chosen = _find_plugin(candidates, default_pkg)
        if chosen:
            return struct(chosen = chosen, default_pkg = default_pkg, candidates = candidates)

    # 4. Else a build-time error that names the umbrella, the platform and every candidate.
    candidate_names = sorted([c.name for c in candidates if c.name != umbrella_name])
    if not candidate_names:
        candidate_names = sorted([c.name for c in candidates])
    _fail_multiple_implementations(umbrella_name, target_platform, ", ".join(candidate_names), "")
    return None

def _collect_umbrella_names(plugins, target_platform):
    """Collects umbrella names for target_platform from plugin metadata."""
    umbrellas = {}
    for p in plugins:
        info = _platform_info(p, target_platform)
        if not info:
            continue
        default_pkg = info.get("default_package", "")
        if default_pkg:
            umbrellas[p.name] = True
        impl = getattr(p, "implements", "")
        if impl:
            umbrellas[impl] = True
    return umbrellas.keys()

def _drop_other_candidates(candidates, chosen_name, preserve_name, dropped):
    """Marks candidates other than chosen_name and preserve_name to be dropped.

    Args:
        candidates: List of candidate plugin structs.
        chosen_name: Name of the chosen plugin.
        preserve_name: Name of an additional package to preserve, or None.
        dropped: Dict of package names to drop.
    """
    for c in candidates:
        if c.name == chosen_name or c.name == preserve_name:
            continue
        dropped[c.name] = True

def _record_umbrella_resolution(match, u_name, replacements, dropped, chosen_names):
    """Records replacements and dropped packages for one resolved umbrella.

    Args:
        match: Resolution struct(chosen, default_pkg, candidates).
        u_name: Umbrella package name.
        replacements: Dict mapping umbrella package name to replacement plugin.
        dropped: Dict of package names to drop.
        chosen_names: Dict of chosen package names.
    """
    chosen = match.chosen
    default_pkg = match.default_pkg

    if default_pkg and chosen.name != default_pkg:
        dropped[default_pkg] = True

    preserve_name = u_name if chosen.name == default_pkg or chosen.name == u_name else None
    if not preserve_name:
        replacements[u_name] = chosen
        chosen_names[chosen.name] = True

    _drop_other_candidates(match.candidates, chosen.name, preserve_name, dropped)

def _find_federated_resolution(plugins, target_platform):
    """Finds replacements and dropped packages for federated plugins on target_platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.

    Returns:
        A struct with replacements, dropped, and chosen_names dicts.
    """
    replacements = {}
    dropped = {}
    chosen_names = {}

    umbrella_names = _collect_umbrella_names(plugins, target_platform)
    for u_name in umbrella_names:
        match = _resolve_one_umbrella(u_name, plugins, target_platform)
        if match:
            _record_umbrella_resolution(match, u_name, replacements, dropped, chosen_names)

    return struct(
        replacements = replacements,
        dropped = dropped,
        chosen_names = chosen_names,
    )

def _filter_resolved_plugins(plugins, replacements, dropped, chosen_names):
    """Applies federated replacements and drops to the plugin list.

    Args:
        plugins: List of plugin structs.
        replacements: Dict mapping umbrella plugin name to chosen replacement struct.
        dropped: Dict of package names to drop.
        chosen_names: Dict of chosen package names.

    Returns:
        List of resolved plugin structs.
    """
    result = []
    seen_chosen = {}

    for p in plugins:
        if p.name in dropped:
            continue
        target = replacements.get(p.name, p)
        if target.name in chosen_names:
            if target.name not in seen_chosen:
                seen_chosen[target.name] = True
                result.append(target)
            continue
        result.append(p)

    return result

def resolve_federated_plugins(plugins, target_platform):
    """Resolve federated plugin implementations for the given platform.

    Federated plugin resolution follows Flutter's resolvePlatformImplementation
    order per target platform: single candidate, direct candidate, endorsed
    default_package, or build-time error naming candidates.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform name (e.g. 'android', 'ios').

    Returns:
        The resolved list of plugins with defaults replaced or dropped.
    """
    if not plugins or not target_platform:
        return plugins

    resolution = _find_federated_resolution(plugins, target_platform)
    if not resolution.replacements and not resolution.dropped:
        return plugins

    return _filter_resolved_plugins(
        plugins,
        resolution.replacements,
        resolution.dropped,
        resolution.chosen_names,
    )
