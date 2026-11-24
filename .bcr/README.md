# Bazel Central Registry

When a module is released, we want it published to the
Bazel Central Registry automatically:
<https://registry.bazel.build>

This folder holds the templates that automate the publish step, one folder per
module (`rules_dart/`, `rules_flutter/`): the publish workflow runs with the
module's directory as its `module_roots`, and reads the templates from
`.bcr/<module>/`. A module's tags carry its name (`rules_dart-v0.29.0`), so the
workflow is called with `tag_prefix: rules_dart-v`. The release archive holds
the module only, with `MODULE.bazel` at the top of its `strip_prefix`
directory, and is named `rules_dart-v<version>.tar.gz`, which is what
`source.template.json` names.

See <https://github.com/bazel-contrib/publish-to-bcr/blob/main/templates/README.md>
for authoritative documentation about these files, and `RELEASING.md` at the root for
the release steps.
