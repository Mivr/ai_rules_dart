"""YAML files read as data, and what the pub rules read from `pubspec` data.

Public entry point for rule sets that read `pubspec.yaml`, `pubspec.lock` or
another YAML file (a CocoaPods `Podfile.lock`, say) the way rules_dart does:
one pinned `yaml2json` process converts every file a step needs to JSON, and
Starlark decodes it. Load from `//dart/pub:yaml.bzl`, not from
`//dart/pub/private`, which is not public.

Conversion (`yaml_to_json`, `yaml_to_json_or_error`): callable from a module
extension or a repository rule, never at loading or analysis time. Booleans
arrive as booleans, `null`, `~` and empty values as None, and every other
scalar as a string holding its source text (`1.10` stays `"1.10"`, `700` and
`"700"` both read `"700"`). A file that is not YAML, repeats a mapping key,
holds more than one document or has no mapping at the top level is an error
naming the file; an empty or comment-only file reads as `{}`.

Projection (`lock_packages`, `lock_packages_or_error`, `pubspec_deps`,
`pubspec_sdk_constraint`, `pubspec_environment_error`): the checks `pub`
makes on a decoded lock and pubspec, with the shapes the pub rules consume.
The files behind these and the conversion are `READER_SOURCE_LABELS` in
`//dart/pub:pub_scc.bzl`, which a facts key digests.
"""

load(
    "//dart/pub/private:pubspec_data.bzl",
    _lock_packages = "lock_packages",
    _lock_packages_or_error = "lock_packages_or_error",
    _pubspec_deps = "pubspec_deps",
    _pubspec_environment_error = "pubspec_environment_error",
    _pubspec_sdk_constraint = "pubspec_sdk_constraint",
)
load(
    "//dart/pub/private:yaml2json.bzl",
    _yaml_to_json = "yaml_to_json",
    _yaml_to_json_or_error = "yaml_to_json_or_error",
)

visibility("public")

# Conversion: files in, one top-level mapping per file out.
yaml_to_json = _yaml_to_json
yaml_to_json_or_error = _yaml_to_json_or_error

# Projection of decoded `pubspec.lock` and `pubspec.yaml` data.
lock_packages = _lock_packages
lock_packages_or_error = _lock_packages_or_error
pubspec_deps = _pubspec_deps
pubspec_sdk_constraint = _pubspec_sdk_constraint
pubspec_environment_error = _pubspec_environment_error
