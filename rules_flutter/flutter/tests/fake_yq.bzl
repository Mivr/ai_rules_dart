"""A stand-in for the `yq` process behind `yaml_to_json`, for mock repository contexts.

`yaml_to_json` (`@rules_dart//dart/pub:yaml.bzl`) runs
`ctx.execute([yq, flags..., expression, files...])` and decodes one JSON line
per document, `{"file", "doc", "duplicate_keys", "data"}`. A mock context
built with these pieces answers that call from the decoded mapping the test
holds, so unit tests hand rules_flutter exactly what a real `Podfile.lock`
or `pubspec.yaml` converts to. The mock's `path()` must return a YAML
file's key itself (a string), so that key is the file name on the command
line.
"""

visibility(["//flutter/tests/..."])

FAKE_YQ_OS = struct(name = "linux", arch = "amd64")

def fake_yq_execute(yaml_files):
    """An `execute` answering `yaml_to_json` from decoded data.

    Args:
        yaml_files: Each YAML file's key (the string the mock's `path()`
            returns for it) mapped to its decoded top-level mapping.

    Returns:
        A function with `repository_ctx.execute`'s calling convention.
    """

    def _execute(args, **_kwargs):
        lines = [
            json.encode({"data": yaml_files[arg], "doc": 0, "duplicate_keys": False, "file": arg})
            for arg in args
            if type(arg) == "string" and arg in yaml_files
        ]
        return struct(return_code = 0, stdout = "\n".join(lines) + "\n", stderr = "")

    return _execute

def fake_yq_watch(_path):
    """A `watch` that records nothing."""
