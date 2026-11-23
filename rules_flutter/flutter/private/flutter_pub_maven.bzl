"""Android Maven inputs shared by the hosted and path pub spoke rules.

Both `flutter_pub_package` and `flutter_pub_path_package` run the same spoke
generator, which reads `android_maven_deps` and `android_maven_ignore` from
the repository context. The attribute declarations live here once so a path
plugin's `android/build.gradle*` is translated exactly like a hosted
plugin's, and `path_spoke_maven_inputs` names the pair the extension hands to
every path spoke.
"""

visibility(["//flutter/..."])

# `flutter.pub(android_maven_deps)` additions to the built-in
# Gradle-to-`@rules_android_maven` mapping. A plugin's runtime dependency
# whose coordinate is in neither table fails the fetch; mapping it here is
# the fix for external artifacts.
maven_deps_attr = attr.string_dict(
    doc = "`group:artifact` -> Bazel label additions to the built-in " +
          "Gradle-to-`@rules_android_maven` mapping, from " +
          "`flutter.pub(android_maven_deps)`. A plugin's " +
          "`android/build.gradle*` runtime dependency whose " +
          "coordinate is in neither table fails the fetch; mapping " +
          "it here is the fix for external artifacts.",
    default = {},
)

# `flutter.pub(android_maven_ignore)` coordinates that need no Bazel label.
# Listing one leaves it out of the spoke's deps instead of failing the fetch
# as unknown; it is always a deliberate declaration, never a default.
maven_ignore_attr = attr.string_list(
    doc = "`group:artifact` coordinates that need no Bazel label, " +
          "from `flutter.pub(android_maven_ignore)`. A coordinate " +
          "listed here is left out of the spoke's deps instead of " +
          "failing the fetch as unknown. This is a declaration you " +
          "make deliberately; it is never a default.",
    default = [],
)

def path_spoke_maven_inputs(pub_tag):
    """The Android Maven inputs a path spoke receives from `flutter.pub`.

    Args:
        pub_tag: The `flutter.pub` tag, carrying both Maven attributes from
            the hub's `MODULE.bazel`.

    Returns:
        struct(deps, ignore): the mapping and the coordinates to leave out,
        ready for the path spoke's repository attributes.
    """
    return struct(
        deps = pub_tag.android_maven_deps,
        ignore = pub_tag.android_maven_ignore,
    )
