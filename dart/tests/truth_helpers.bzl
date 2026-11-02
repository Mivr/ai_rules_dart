"""Shared `rules_testing` helpers for the direct rule tests in this package.

Every direct test registers its subject through `@rules_testing//lib:analysis_test.bzl`
and reads the target's providers and actions through the `truth` subjects. The
helpers below remove the boilerplate that would otherwise repeat in each test:
turning one of this repository's struct providers into a subject, fetching a
registered action by mnemonic, and asserting on an action's inputs by path
pattern.
"""

load("@rules_testing//lib:truth.bzl", "matching", "subjects")

WINDOWS_ATTR = {
    "_windows": attr.label(
        doc = "Platform constraint probed to match `.exe` executable suffixes on Windows.",
        default = Label("@platforms//os:windows"),
    ),
}

def exe_extension(env):
    """Returns `".exe"` when the test target platform is Windows, else `""`.

    Args:
      env: The `analysis_test` environment (from a test declaring `WINDOWS_ATTR`).

    Returns:
      `".exe"` on Windows, `""` elsewhere.
    """
    is_windows = env.ctx.target_platform_has_constraint(
        env.ctx.attr._windows[platform_common.ConstraintValueInfo],
    )
    return ".exe" if is_windows else ""

def provider_subject(attrs):
    """Builds the subject factory `TargetSubject.provider` needs for a struct provider.

    Args:
      attrs: `dict[str, callable]`: each provider field to assert on, mapped to
        the `subjects` factory (for example `subjects.str`) that wraps it.

    Returns:
      A `factory(value, *, meta)` callable for `TargetSubject.provider`.
    """

    def factory(value, *, meta):
        """Wraps one provider instance in a struct subject over `attrs`."""
        return subjects.struct(value, meta = meta, attrs = attrs)

    return factory

def short_path_subject(value, *, meta):
    """Subject factory for a `File` or `None` provider field, compared by `short_path`.

    Args:
      value: A `File`, or `None`.
      meta: The `ExpectMeta` of the call chain.

    Returns:
      A `StrSubject` of the `short_path`, or of the empty string for `None`.
    """
    return subjects.str("" if value == None else value.short_path, meta = meta)

def short_paths(value, *, meta):
    """Subject factory for a list of `File`s, compared by `short_path`.

    Args:
      value: A list of `File`s.
      meta: The `ExpectMeta` of the call chain.

    Returns:
      A `CollectionSubject` of the files' `short_path`s.
    """
    return subjects.collection([f.short_path for f in value], meta = meta, container_name = "files")

def package_names(value, *, meta):
    """Subject factory for list, tuple or depset of package records, compared by name.

    Args:
      value: Records with a `package_name` field (`DartPackageInfo`).
      meta: The `ExpectMeta` of the call chain.

    Returns:
      A `CollectionSubject` of the records' `package_name`s.
    """
    records = value.to_list() if type(value) == "depset" else value
    return subjects.collection([p.package_name for p in records], meta = meta, container_name = "packages")

def asset_ids(value, *, meta):
    """Subject factory for a list or tuple of `DartCodeAssetInfo`, compared by `asset_id`.

    Args:
      value: `DartCodeAssetInfo` records.
      meta: The `ExpectMeta` of the call chain.

    Returns:
      A `CollectionSubject` of the records' `asset_id`s.
    """
    return subjects.collection([a.asset_id for a in value], meta = meta, container_name = "code assets")

def provider_of(env, target, provider, name, attrs):
    """Returns the subject of one provider a target publishes.

    Fails the test when the target does not publish the provider.

    Args:
      env: The `analysis_test` environment.
      target: The target under test.
      provider: The provider symbol, for example `DartInfo`.
      name: Display name of the provider in failure messages.
      attrs: `dict[str, callable]`: provider fields to expose, as for
        `provider_subject`.

    Returns:
      A struct subject whose field accessors return the field subjects.
    """
    subject = env.expect.that_target(target)
    subject.has_provider(provider, name)
    return subject.provider(provider, factory = provider_subject(attrs), provider_name = name)

def action_of(env, target, mnemonic):
    """Returns the subject of the target's single action with `mnemonic`.

    Args:
      env: The `analysis_test` environment.
      target: The target under test.
      mnemonic: The action mnemonic, for example `DartCodegen`.

    Returns:
      An `ActionSubject`.
    """
    return env.expect.that_target(target).action_named(mnemonic)

def expect_inputs(action, patterns):
    """Asserts that an action's inputs include a file for each path pattern.

    Args:
      action: An `ActionSubject`.
      patterns: `list[str]`: glob patterns (`*` matches anything) over each
        input's exec path.
    """
    action.inputs().contains_at_least_predicates(
        [matching.file_path_matches(p) for p in patterns],
    )

def expect_default_outputs(env, target, outputs):
    """Asserts a target's `DefaultInfo.files` are exactly the given outputs.

    Args:
      env: The `analysis_test` environment.
      target: The target under test.
      outputs: `list[str]`: expected `short_path` of each file; `{package}` and
        `{name}` expand to the test target's package and name.
    """
    env.expect.that_target(target).default_outputs().contains_exactly(outputs)

def expect_executable_symlink(env, target, tool_pattern):
    """Asserts the target's executable is a symlink to the given tool.

    Args:
      env: The `analysis_test` environment.
      target: The target under test.
      tool_pattern: Glob over the exec path of the symlinked tool, as for
        `expect_inputs`.
    """
    action = action_of(env, target, "ExecutableSymlink")
    expect_inputs(action, [tool_pattern])
    executable = target[DefaultInfo].files_to_run.executable
    env.expect.that_depset_of_files(action.actual.outputs).contains_exactly([executable.short_path])
