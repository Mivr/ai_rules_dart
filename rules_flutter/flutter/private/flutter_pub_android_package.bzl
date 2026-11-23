"""The lazy Android half of a `flutter.pub` plugin spoke.

A plugin's Gradle model is read here, in its own repository, only when an
Android target analyses the spoke's `android:lib` alias. The spoke fetch never
touches `android/build.gradle` / `build.gradle.kts`, so an iOS-, macOS-, web-
or Dart-only consumer can resolve a hub whose plugins declare coordinates
rules_flutter cannot translate; the refusal fires only when the model is
actually needed.

`flutter_pub_android_package` carries either the hosted package archive or the
path package's `android` platform directory, reads the one Gradle build
Gradle would evaluate, and emits the same `kt_android_library` the spoke used
to emit. `android_package_repo_name` and `android_spoke_alias_content` are the
pure pieces the spoke generator and its unit tests consume.
"""

load(":flutter_pub_apple.bzl", _has_files_under = "has_files_under")
load(":flutter_pub_maven.bzl", "maven_deps_attr", "maven_ignore_attr")
load(
    ":flutter_pub_mirror.bzl",
    "detect_case_insensitive_host",
    "link_scoped_file_entry",
    "make_link_scope",
    "outside_workspace_refusal",
    "path_spoke_resolves_outside",
)
load(":flutter_pub_scan.bzl", "fetch_hosted_archive", "scan_hosted_archive", "walk_hosted_package")
load(
    ":flutter_pubspec.bzl",
    "parse_flutter_plugin_block",
)
load(
    ":gradle.bzl",
    "detect_android_namespace",
    "detect_android_native_build",
    "detect_consumer_proguard_specs",
    "plugin_android_build",
    "resolve_plugin_maven_deps",
    _gradle_is_java_package_name = "is_java_package_name",
)
load(":starlark_literal.bzl", "starlark_string_literal")

visibility(["//flutter/..."])

# Kotlin/Java source extensions for Android plugin libraries.
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

# The one neverlink engine every plugin library compiles against.
_SHARED_ANDROID_ENGINE = "@rules_flutter//flutter:android_plugin_engine"

def android_package_repo_name(hub_name, package_name):
    """The deterministic Android repository name for one hub and package.

    The `-` separator cannot appear in a pub package name, so this name never
    collides with a spoke (`<hub>__<package>`) even when the package name
    itself starts with `android`.

    Args:
        hub_name: The `flutter.pub` hub repository name.
        package_name: The pub package name.

    Returns:
        `<hub>-android-<package>`, the repository holding the Gradle model.
    """
    return hub_name + "-android-" + package_name

def android_spoke_alias_content(android_repo_name):
    """The spoke's `android/BUILD.bazel`: one alias, and no `load()`.

    The aggregator depends on this `lib` target exactly as it did before; the
    alias's `actual` is the plugin's Android repository, so analysing the
    alias is what fetches and reads the Gradle model.

    Args:
        android_repo_name: The repository from `android_package_repo_name`.

    Returns:
        Generated BUILD content naming only the Android repository.
    """
    return """\
# The Gradle model lives in this plugin's Android repository and is read
# only when an Android target analyses this alias.
alias(
    name = "lib",
    actual = "@{repo}//android:lib",
    visibility = ["//visibility:public"],
)
""".format(repo = android_repo_name)

def _detect_android_source_dir(ctx, package_name):
    """Return the Android source dir if it contains Kotlin/Java files.

    Pub plugins use the standard Android directory layout
    `android/src/main/{kotlin,java}/`.

    Args:
        ctx: The Android repository context.
        package_name: The pub package the sources belong to.

    Returns:
        `android/src/main` when it holds Kotlin/Java files, else `""`.
    """
    if _has_files_under(ctx, "android/src/main", _ANDROID_SRC_EXTENSIONS, package_name):
        return "android/src/main"
    return ""

def _detect_android_resources(ctx, package_name):
    """True when the plugin ships Android resources at `android/src/main/res/`.

    The standard AGP resource location. Detected resources are compiled
    into the generated `kt_android_library` via `resource_files` so the
    plugin's `R` class resolves and the resources merge into the
    consuming APK — same as any Gradle-built Android library.

    Args:
        ctx: The Android repository context.
        package_name: The pub package the resources belong to.

    Returns:
        True when any file exists under `android/src/main/res/`.
    """
    return _has_files_under(ctx, "android/src/main/res", None, package_name)

def _detect_android_manifest(ctx):
    """Return the plugin's `android/src/main/AndroidManifest.xml` path if present.

    AGP's `ManifestMerger2` combines each Android library's manifest into
    the consuming app's final AndroidManifest.xml at build time. Plugins
    routinely declare `<activity>`, `<service>`, `<receiver>`,
    `<provider>`, `<uses-permission>`, and `<queries>` entries this way
    (e.g. url_launcher_android's WebViewActivity, record_android's
    RECORD_AUDIO permission). `rules_android`'s `android_binary` runs
    the equivalent merger over its dep graph; a `kt_android_library`
    (which extends `android_library`) participates if it sets
    `manifest = "..."`. Returns the path relative to the repository root,
    or empty when the plugin ships no manifest.

    Args:
        ctx: The Android repository context.

    Returns:
        The repository-relative manifest path, or `""`.
    """
    if ctx.path("android/src/main/AndroidManifest.xml").exists:
        return "android/src/main/AndroidManifest.xml"
    return ""

def _make_android_native_build_unsupported_content(package_name, version):
    """Generate an `android/BUILD.bazel` that fails at load time.

    Emitted for plugins whose Gradle build compiles native code for Android
    (externalNativeBuild) when no overlay provides a Bazel translation.
    Android targets that depend on the plugin (or on the hub's
    `android:all_android_plugin_libs` aggregator) load this file and fail with
    a clear message; unrelated apps and non-Android platforms never load it.

    Args:
        package_name: The pub package whose native build cannot be modelled.
        version: The locked package version, for the message.

    Returns:
        Generated BUILD content whose only statement is `fail(...)`.
    """
    message = (
        "package:{pkg} {version} compiles native code for Android via " +
        "Gradle's externalNativeBuild, which rules_flutter cannot " +
        "translate automatically. An APK built without that library would " +
        "crash at plugin registration, so this is a hard error. Provide a " +
        "plugin overlay for {pkg} (flutter.plugin_overlays in MODULE.bazel) " +
        "that compiles the package's native sources with cc_shared_library " +
        "and ships them through flutter_plugin.native_deps — see " +
        "@rules_flutter//ext/jni for the canonical example."
    ).format(pkg = package_name, version = version)

    # The message names a classified package name and a lock version; the
    # whole text still renders as one escaped literal, never spliced raw.
    return "fail(" + starlark_string_literal(message) + ")\n"

def _android_manifest_build_args(android_manifest, java_package, has_resources):
    """Return the `(manifest_arg, synthesized_manifest)` BUILD fragments.

    `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick up
    the plugin's entries transitively; `exports_manifest = 1` opts into
    the merger (rules_android defaults to no, AGP to yes). rules_android
    requires *some* manifest whenever `resource_files` is set, so a
    res-bearing plugin with no manifest gets a synthesized namespaced
    empty one, the way AGP treats a missing library manifest.

    Args:
        android_manifest: The repository-relative manifest path, or `""`.
        java_package: The plugin's Android namespace.
        has_resources: True when `android/src/main/res/` holds files.

    Returns:
        `(manifest_arg, synthesized_manifest)` BUILD fragments.
    """
    if android_manifest:
        sub_manifest = android_manifest
        if sub_manifest.startswith("android/"):
            sub_manifest = sub_manifest[len("android/"):]

        # The manifest path is a fixed plugin layout location; it renders
        # through the escaping helper like every other emitted string.
        return ("    manifest = %s,\n    exports_manifest = 1,\n" % starlark_string_literal(sub_manifest), "")
    if not has_resources:
        return ("", "")
    manifest_lines = [
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
        "    package=\"" + java_package + "\">",
        "</manifest>",
        "",
    ]
    manifest_content = "\n".join(["        %s," % starlark_string_literal(line) for line in manifest_lines])
    synthesized = """
# Minimal manifest for resource processing. AGP treats a missing library
# manifest as an empty one; rules_android requires an explicit file when
# resource_files is set.
write_file(
    name = "_manifest",
    out = "_manifest/AndroidManifest.xml",
    content = [
{content}
    ],
    newline = "unix",
)
""".format(content = manifest_content)
    return ('    manifest = ":_manifest",\n', synthesized)

def _build_config_path(bc_package):
    """The `android/`-relative path of the generated BuildConfig source.

    Args:
        bc_package: The Java package for the generated BuildConfig class.

    Returns:
        The relative path.
    """
    return "_build_config/" + bc_package.replace(".", "/") + "/BuildConfig.java"

def android_build_config_source(java_package):
    """Return the BuildConfig stub a plugin's `lib` compiles as a source.

    Gradle synthesizes BuildConfig per Android module (matching
    `android.namespace`) inside the module's own compile; rules_android does
    not, so the repository writes a minimal one beside the plugin's sources.
    `DEBUG = false` is the safe default; the engine ABI / mode is decided
    elsewhere.

    Args:
        java_package: The plugin's Android namespace, or `""`.

    Returns:
        `struct(path, content)`: the `android/`-relative file path and text.
    """
    bc_package = java_package if java_package else "_unknown"
    return struct(
        path = _build_config_path(bc_package),
        content = "\n".join([
            "package " + bc_package + ";",
            "public final class BuildConfig {",
            "  public static final boolean DEBUG = false;",
            "  public static final String LIBRARY_PACKAGE_NAME = \"" + bc_package + "\";",
            "  public static final String BUILD_TYPE = \"release\";",
            "}",
            "",
        ]),
    )

def _fail_on_invalid_android_namespace(package_name, java_package):
    """Fail the Android repository fetch when the namespace is not a package.

    Args:
        package_name: The pub package the namespace belongs to.
        java_package: The resolved namespace, possibly empty.
    """
    if java_package and not _gradle_is_java_package_name(java_package):
        fail((
            "flutter.pub spoke for \"{pkg}\": the Android namespace " +
            "{ns} is not a valid Java package name (checked " +
            "android.namespace in build.gradle(.kts), the " +
            "AndroidManifest.xml package attribute, and " +
            "flutter.plugin.platforms.android.package in " +
            "pubspec.yaml). Refusing it rather than emitting it " +
            "into the generated android/BUILD.bazel."
        ).format(
            pkg = package_name,
            ns = repr(java_package),
        ))

def _android_srcs_attr(android_src_dir, bc_path):
    """The `srcs` attribute value for the generated `kt_android_library`.

    The source dir is relative to the repository root; the sub-package itself
    lives at `android/`, so that prefix is stripped there. The generated
    BuildConfig is always one of the sources.

    Args:
        android_src_dir: The repository-relative Android source dir, or `""`.
        bc_path: The `android/`-relative BuildConfig.java path.

    Returns:
        A BUILD `srcs` expression.
    """
    bc_src = "[%s]" % starlark_string_literal(bc_path)
    if not android_src_dir:
        return bc_src
    if android_src_dir.startswith("android/"):
        sub_src = android_src_dir[len("android/"):]
    else:
        sub_src = android_src_dir
    return "glob([{kt}, {java}], allow_empty = True) + {bc}".format(
        kt = starlark_string_literal(sub_src + "/**/*.kt"),
        java = starlark_string_literal(sub_src + "/**/*.java"),
        bc = bc_src,
    )

def _android_library_args(java_package, android_manifest, has_resources, consumer_proguard_specs):
    """The manifest, resources and ProGuard fragments of the library.

    Returns `struct(custom_package, manifest, synthesized_manifest,
    resource_files, proguard_specs)`. `manifest = "..."` lets
    `android_binary`'s `ManifestMerger2` pick up the plugin's `<activity>` /
    `<service>` / `<uses-permission>` / etc. entries transitively — same
    shape AGP uses inside `flutter build apk`. Paths are relative to the
    `android/` sub-package, so the prefix is stripped there. Resources are
    compiled into the library so the plugin's `R` class resolves at compile
    time and the resources merge into the consuming APK. `proguard_specs`
    lets `android_binary`'s R8 step pick up the plugin's keep rules
    transitively — same shape AGP uses for `consumerProguardFiles`.

    Args:
        java_package: The plugin's Android namespace, or `""`.
        android_manifest: The repository-relative manifest path, or `""`.
        has_resources: True when resources exist under `src/main/res/`.
        consumer_proguard_specs: Android-subpackage-relative keep-rule paths.

    Returns:
        The `struct` of rendered BUILD fragments.
    """
    custom_package_arg = ""
    if java_package:
        # Validated as a Java package name before the BUILD renders, so
        # quotefree; still helper-rendered like every emitted string.
        custom_package_arg = "    custom_package = %s,\n" % starlark_string_literal(java_package)

    (manifest_arg, synthesized_manifest) = _android_manifest_build_args(
        android_manifest,
        java_package,
        has_resources,
    )

    # `allow_empty = False` — resource detection already saw files here, so
    # an empty glob means the layout assumption broke.
    resource_files_arg = ""
    if has_resources:
        resource_files_arg = '    resource_files = glob(["src/main/res/**"], allow_empty = False),\n'

    proguard_specs_arg = ""
    if consumer_proguard_specs:
        # Keep-rule paths are single-quoted Gradle literals resolved by the
        # lexed model; each renders through the escaping helper.
        spec_lines = ", ".join([starlark_string_literal(path) for path in consumer_proguard_specs])
        proguard_specs_arg = "    proguard_specs = [%s],\n" % spec_lines

    return struct(
        custom_package = custom_package_arg,
        manifest = manifest_arg,
        synthesized_manifest = synthesized_manifest,
        resource_files = resource_files_arg,
        proguard_specs = proguard_specs_arg,
    )

def _android_plugin_deps_block(extra_maven_labels):
    """The `deps` block body: the shared engine plus maven labels.

    Base dep every plugin gets: the one compile-only engine the rules define
    (it carries the FlutterPlugin SPI plus the embedding's androidx compile
    classpath via its exports). Plugin-specific maven deps from
    `extra_maven_labels` are appended, de-duped.

    Args:
        extra_maven_labels: Translated `@rules_android_maven` labels.

    Returns:
        The comma-separated deps body.
    """
    base_labels = [_SHARED_ANDROID_ENGINE]
    seen = {label: True for label in base_labels}
    all_labels = list(base_labels)
    for lbl in extra_maven_labels:
        if lbl not in seen:
            seen[lbl] = True
            all_labels.append(lbl)

    # Base labels are fixed; maven labels arrive validated quotefree from
    # the extension. Each still renders through the escaping helper, so a
    # hostile value lands inert instead of breaking out of the list.
    return "\n        ".join([starlark_string_literal(label) + "," for label in all_labels])

def _android_load_prelude():
    """The `load()` half of the Android sub-package content.

    Returns:
        The BUILD fragment holding the `kt_android_library` load.
    """
    return """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

"""

def _android_lib_target(srcs_attr, lib_args, deps_block):
    """The `kt_android_library(name = "lib")` half, manifest included.

    Args:
        srcs_attr: The rendered `srcs` expression.
        lib_args: The `struct` from `_android_library_args`.
        deps_block: The rendered deps body.

    Returns:
        The BUILD fragment holding the plugin's public `lib` target.
    """
    return """\
{synthesized_manifest}
kt_android_library(
    name = "lib",
    srcs = {srcs},
{custom_package}{manifest}{resource_files}{proguard_specs}    visibility = ["//visibility:public"],
    deps = [
        {deps}
    ],
)
""".format(
        srcs = srcs_attr,
        custom_package = lib_args.custom_package,
        manifest = lib_args.manifest,
        resource_files = lib_args.resource_files,
        proguard_specs = lib_args.proguard_specs,
        deps = deps_block,
        synthesized_manifest = lib_args.synthesized_manifest,
    )

def make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        extra_maven_labels,
        android_manifest = "",
        consumer_proguard_specs = [],
        has_resources = False):
    """Generate `android/BUILD.bazel` content for a Flutter plugin repository.

    Always emits a `kt_android_library(name = "lib", ...)`. The aggregator
    in the hub's `android/all_android_plugin_libs` depends on `:lib` for
    every spoke; plugins without Android sources still contribute an empty
    library (a no-op at link time).

    Loaded lazily — Bazel only parses this file when something analyses
    `@<android-repo>//android:lib`. Non-Android workspaces never trigger it
    and don't pay the `@rules_android` / `@rules_kotlin` cost.

    The `_engine` target gives the plugin's Kotlin/Java source access to
    the FlutterPlugin SPI on the compile classpath. It is `neverlink`, as
    Gradle gives a plugin the embedding with `compileOnly`: the app
    packages its own engine, of the ABI its
    `flutter_android_app(android_abi = ...)` names. The plugin's is the
    arm64 one whatever the app's ABI, since Java bytecode is
    ABI-independent, and packaged it would put an arm64 engine in an x64
    APK. The engine also exports the embedding's
    androidx dependencies (see `_ANDROIDX_EMBEDDING_DEPS` in
    `flutter/android.bzl`), so a plugin whose `build.gradle` declares no
    dependencies still compiles against `NotificationCompat` & co. —
    exactly the compile classpath Gradle gives it via the
    `io.flutter:flutter_embedding_*` POM.

    BuildConfig.java is generated from the plugin's `java_package`. Many
    Flutter plugins reference `BuildConfig.DEBUG`, which Gradle synthesizes
    automatically; rules_android does not. We emit a minimal stub so the
    plugin's source compiles. `DEBUG = false` is the safe default —
    Flutter's Bazel build is release-by-default; debug runtime semantics
    are governed by `flutter_android_engine`'s engine selection, not by
    `BuildConfig.DEBUG`.

    Args:
        android_src_dir: Source dir under the repository root (e.g.
            `android/src/main`) when there are Android sources, or empty
            when there aren't.
        java_package: The plugin's Android namespace — resolved the way
            AGP resolves it (`android.namespace` in `build.gradle(.kts)`,
            else the manifest's `package` attribute), falling back to
            `flutter.plugin.platforms.android.package` from the pubspec.
            Used as `custom_package` on the `kt_android_library` so the
            generated `R` and `BuildConfig` classes land in the package
            the plugin's sources expect.
        extra_maven_labels: Additional `@rules_android_maven//:...`
            labels parsed from the plugin's `build.gradle*` and translated
            via `maven_labels_for_gradle` (the built-in table plus
            `flutter.pub(android_maven_deps)`).
        android_manifest: Path to the plugin's
            `android/src/main/AndroidManifest.xml` if it ships one, or
            empty. When set, the generated `kt_android_library` declares
            `manifest = ...` so `android_binary`'s manifest merger
            (`ManifestMerger2`) picks the plugin's `<activity>` /
            `<service>` / `<uses-permission>` / etc. entries up
            transitively — same shape AGP uses inside `flutter build apk`.
        consumer_proguard_specs: Paths (relative to the repository's
            `android/` sub-package) to ProGuard / R8 keep-rule files
            the plugin declared via `consumerProguardFiles` in its
            `build.gradle`. Threaded through as `proguard_specs = [...]`
            on the generated `kt_android_library`; rules_android
            propagates them transitively to the consuming
            `android_binary`'s R8 invocation, mirroring AGP's
            `consumerProguardFiles` flow.
        has_resources: True when the plugin ships resources at
            `android/src/main/res/`. Compiled via `resource_files` so the
            plugin's `R` class is generated against `java_package` and
            the resources merge into the consuming APK.

    Returns:
        Generated BUILD content as a string.

    Every string below renders through the escaping helper, never
    `"..." % value`: the namespace, manifest paths and labels arrive from
    plugin files and user attributes, and a hostile value must at worst land
    inert inside a string literal, never break out of one. A non-empty
    `java_package` that is not a Java package name (see
    `is_java_package_name`) fails instead of rendering at all.
    """
    if java_package and not _gradle_is_java_package_name(java_package):
        fail(
            "make_android_subpackage_build_content: java_package " +
            repr(java_package) + " is not a valid Java package name.",
        )
    if not android_src_dir and not has_resources:
        # Empty kt_android_library is valid in rules_kotlin. The hub's
        # aggregator depends on this repository's `:lib` unconditionally,
        # so this no-op contribution keeps the deps list mechanical.
        return """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
"""

    if has_resources and not java_package:
        fail(
            "Plugin ships Android resources (android/src/main/res/) but " +
            "declares no namespace — checked android.namespace in " +
            "build.gradle(.kts), the AndroidManifest.xml package " +
            "attribute, and flutter.plugin.platforms.android.package in " +
            "pubspec.yaml. Without a namespace the R class cannot be " +
            "generated, so the resources would not compile.",
        )

    srcs_attr = _android_srcs_attr(android_src_dir, android_build_config_source(java_package).path)

    lib_args = _android_library_args(
        java_package,
        android_manifest,
        has_resources,
        consumer_proguard_specs,
    )

    deps_block = _android_plugin_deps_block(extra_maven_labels)

    return _android_load_prelude() + _android_lib_target(
        srcs_attr,
        lib_args,
        deps_block,
    )

def detect_android_plugin_sources(ctx, plugin_block):
    """Detect the Android side when `pluginClass` is set on `android`.

    The plugin's Android Gradle build is ONE consistent model: Gradle
    evaluates exactly one build file per project directory, so every reader
    below shares `plugin_android_build`'s single choice (see
    `gradle_build_file_choice`). Namespace resolution mirrors AGP (gradle
    `android.namespace`, else the manifest `package` attribute). The
    pubspec's `package` field locates the plugin class for the registrant;
    it only stands in for the namespace when the plugin declares none of
    its own.

    Args:
        ctx: The Android repository context.
        plugin_block: The parsed `flutter.plugin` block.

    Returns:
        `struct(src_dir, java_package, extra_maven_labels, manifest,
        consumer_proguard_specs, has_resources, native_build)`.
    """
    android_info = plugin_block.platforms.get("android", {})
    android_build = struct(path = "", content = "")
    android_native_build = None
    if android_info:
        android_build = plugin_android_build(ctx)
        android_native_build = detect_android_native_build(ctx, android_build.path, android_build.content)

    android_src_dir = ""
    android_java_package = ""
    android_extra_maven_labels = []
    android_manifest = ""
    android_consumer_proguard_specs = []
    android_has_resources = False
    if android_info and android_info.get("pluginClass", ""):
        android_src_dir = _detect_android_source_dir(ctx, ctx.attr.package_name)
        android_has_resources = _detect_android_resources(ctx, ctx.attr.package_name)
        android_java_package = (
            detect_android_namespace(ctx, android_build.path, android_build.content) or
            android_info.get("package", "") or
            ""
        )
        _fail_on_invalid_android_namespace(ctx.attr.package_name, android_java_package)
        if android_src_dir or android_has_resources:
            android_extra_maven_labels = resolve_plugin_maven_deps(ctx, android_build.path, android_build.content)
            android_manifest = _detect_android_manifest(ctx)
            android_consumer_proguard_specs = detect_consumer_proguard_specs(
                ctx,
                android_build.path,
                android_build.content,
            )

    return struct(
        src_dir = android_src_dir,
        java_package = android_java_package,
        extra_maven_labels = android_extra_maven_labels,
        manifest = android_manifest,
        consumer_proguard_specs = android_consumer_proguard_specs,
        has_resources = android_has_resources,
        native_build = android_native_build,
    )

def fail_on_outside_package_path(ctx, package_name, segments, workspace_realpath, case_insensitive = False):
    """Fail when the package dir or any parent component leaves the workspace.

    A path whose intermediate directory is a link out of the workspace
    (`third_party -> /host`) would otherwise be accepted: lexically the
    entry stays inside, but the resolved tree is host bytes. Each prefix
    of the workspace-relative path is resolved and refused, naming the
    package, the offending prefix, and its real path, when it lands
    outside the main workspace's real root. Missing prefixes stop the
    walk: the caller reports the missing directory itself.

    Args:
        ctx: The repository context.
        package_name: The pub package being linked, for the refusal.
        segments: The workspace-relative path split on `/`.
        workspace_realpath: The workspace root's resolved real path.
        case_insensitive: True when the fetch host proves case-insensitive.
    """
    prefix = []
    for segment in segments:
        prefix.append(segment)
        node = ctx.workspace_root.get_child(*prefix)
        if not node.exists:
            break
        target_realpath = str(node.realpath)
        if path_spoke_resolves_outside(workspace_realpath, target_realpath, case_insensitive):
            fail(outside_workspace_refusal(package_name, "/".join(prefix), target_realpath))

def path_package_root(ctx):
    """Resolve a path package's workspace-root directory, refusing escapes.

    Every path spoke and its Android repository use this one validation, so
    an absolute path, a `.`/`..` segment, a missing directory, or any parent
    component resolving outside the workspace fails identically in both.

    Args:
        ctx: A repository context with `path`, `package_name`.

    Returns:
        `struct(src, segments, workspace_realpath, package_realpath,
        case_insensitive)` for the package directory.
    """
    rel = ctx.attr.path
    if rel.startswith("/") or rel in ("", "."):
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} is not a workspace-relative package directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    segments = rel.split("/")
    if ".." in segments or "." in segments or "" in segments:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} escapes its directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    src = ctx.workspace_root.get_child(*segments)
    if not src.exists:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} does not exist under the workspace. Refusing it rather than emitting an empty package.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    workspace_realpath = str(ctx.workspace_root.realpath)
    case_insensitive = detect_case_insensitive_host(ctx, segments)
    fail_on_outside_package_path(ctx, ctx.attr.package_name, segments, workspace_realpath, case_insensitive)
    return struct(
        src = src,
        segments = segments,
        workspace_realpath = workspace_realpath,
        package_realpath = str(src.realpath),
        case_insensitive = case_insensitive,
    )

def _link_path_android_package(ctx):
    """Mirror only the path package's declared `android` platform directory.

    The link plan is the path spoke's, narrowed to the one platform this
    repository serves: file-by-file links, same cycle and workspace
    confinement refusals, and every linked entry watched so a later edit
    refetches the Android repository.

    Args:
        ctx: The Android repository context.
    """
    root = path_package_root(ctx)
    scope = make_link_scope(
        ctx.attr.package_name,
        root.package_realpath,
        root.workspace_realpath,
        root.case_insensitive,
        {},
    )
    link_scoped_file_entry(ctx, root.src, "android", scope)
    ctx.watch(root.src)

def _read_plugin_block(ctx):
    """Parse the plugin block from the package's own pubspec.

    A hosted package reads the extracted `pubspec.yaml`; a path package reads
    it from the workspace without linking it into the repository, so only the
    declared `android` platform directory is mirrored.

    Args:
        ctx: The Android repository context.

    Returns:
        The parsed `flutter.plugin` block (absent defaults when no pubspec).
    """
    if ctx.attr.path:
        root = path_package_root(ctx)
        pubspec_node = root.src.get_child("pubspec.yaml")
        ctx.watch(pubspec_node)
        content = ctx.read(pubspec_node) if pubspec_node.exists else ""
    else:
        pubspec_node = ctx.path("pubspec.yaml")
        content = ctx.read(pubspec_node) if pubspec_node.exists else ""
    return parse_flutter_plugin_block(content)

def _flutter_pub_android_package_impl(ctx):
    """Build the plugin's Android repository from its one Gradle build.

    Args:
        ctx: The repository context.
    """
    if ctx.attr.path:
        _link_path_android_package(ctx)
    else:
        refusal = fetch_hosted_archive(ctx, scan_hosted_archive, walk_hosted_package)
        if refusal:
            fail(refusal)

    android = detect_android_plugin_sources(ctx, _read_plugin_block(ctx))
    if android.native_build:
        ctx.file(
            "android/BUILD.bazel",
            _make_android_native_build_unsupported_content(ctx.attr.package_name, ctx.attr.version),
        )
        return

    if android.src_dir or android.has_resources:
        build_config = android_build_config_source(android.java_package)
        ctx.file("android/" + build_config.path, build_config.content)
    ctx.file(
        "android/BUILD.bazel",
        make_android_subpackage_build_content(
            android_src_dir = android.src_dir,
            java_package = android.java_package,
            extra_maven_labels = android.extra_maven_labels,
            android_manifest = android.manifest,
            consumer_proguard_specs = android.consumer_proguard_specs,
            has_resources = android.has_resources,
        ),
    )

flutter_pub_android_package = repository_rule(
    implementation = _flutter_pub_android_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The locked package version, for refusal messages.",
            default = "",
        ),
        "hub_name": attr.string(
            doc = "The `flutter.pub` hub repository name.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 of the hosted archive, the same value the spoke verifies. A missing or mismatched checksum fails the fetch.",
            default = "",
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository.",
            default = "https://pub.dev",
        ),
        "path": attr.string(
            doc = "Workspace-relative directory of a path package, or empty for a hosted package. A path package's `android` platform directory is linked with the path spoke's confinement rules.",
            default = "",
        ),
        "android_maven_deps": maven_deps_attr,
        "android_maven_ignore": maven_ignore_attr,
    },
    doc = "Reads one Flutter plugin's Android Gradle build and emits the `kt_android_library` the spoke's `android:lib` used to. Created lazily: the spoke's `android:lib` aliases this repository, so only an Android target fetches it.",
)
