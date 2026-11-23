"""YAML files read as JSON: a pinned `yq` binary converts them, Starlark decodes.

`pubspec.lock`, `pubspec.yaml` and `pubspec_overrides.yaml` are YAML. Instead
of parsing YAML in Starlark, the rules run one pinned `yq` process over every
file a step needs and read its JSON output with `json.decode`.

The binary comes from `yq_repository`, a repository rule that downloads the
release asset for the fetch host and checks its published sha256. The `dart`
module extension instantiates it once as `@dart_yq`, and `yaml_to_json`
addresses it through this module's own repo mapping, so it works from any
module extension or repository rule whatever name a consumer gives this
module.

The conversion keeps booleans as JSON booleans, `null`, `~` and empty values
as JSON null, and every other scalar as a string holding its source text, so
`1.10` stays `"1.10"` and a digit-only checksum keeps its digits. It reports
duplicate mapping keys, which `yq` would otherwise let through (and
`json.decode` would resolve silently to the last one). The checks that
`package:yaml` and `pub` make and `yq` does not are made here, naming the
file: no duplicate keys, at most one document, and a mapping at the top level.
An empty or comment-only file reads as an empty mapping.

Everything that decides what a file decodes to lives in this file (the `yq`
release, its checksums, the expression and these checks), so the pub
extension's facts key covers it by digesting this file's bytes.
"""

load("//dart/private:download.bzl", "pinned_download")

visibility(["//dart/..."])

YQ_VERSION = "4.54.3"

_YQ_URL = "https://github.com/mikefarah/yq/releases/download/v{version}/{asset}"

# Release asset and sha256 of the raw binary for every supported fetch host.
# The checksums are the release's published `checksums` (SHA-256 column).
_YQ_BINARIES = {
    "linux-arm64": ("yq_linux_arm64", "89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67"),
    "linux-x64": ("yq_linux_amd64", "129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973"),
    "macos-arm64": ("yq_darwin_arm64", "a2aebb93b5bdcb61bb76f630e42a0ef6a3ee10842a6516cd7b9e4080786ec593"),
    "macos-x64": ("yq_darwin_amd64", "96d5105ffd693d6845c54fbd825b2d1bbdb8619e0a2ce6af95e5654e841e0984"),
    "windows-x64": ("yq_windows_amd64.exe", "066ea0a09a282e47588ec1e1867280ff5ede458f7183617a2d99012e4e34f18a"),
}

# One JSON line per document of every file: the file as named on the command
# line, the document's index in it, whether any mapping in it repeats a key,
# and the data. Booleans and nulls keep their type; every other scalar becomes
# a string holding its source text.
_EXPRESSION = (
    '(.. | select(kind == "scalar" and tag != "!!null" and tag != "!!bool")) tag = "!!str"' +
    ' | {"file": filename, "doc": document_index,' +
    ' "duplicate_keys": ([.. | select(kind == "map") | ((keys | length) != (keys | unique | length))] | any),' +
    ' "data": .}'
)

_FLAGS = [
    "--output-format=json",
    "--indent=0",
    # Explicit keys win over merged ones, as YAML says; no stderr warning.
    "--yaml-fix-merge-anchor-to-spec=true",
    # The expression language's `env()` and `load()` are switched off.
    "--security-disable-env-ops",
    "--security-disable-file-ops",
]

def _host_key(os):
    """Returns the `_YQ_BINARIES` key of the fetch host, failing on an unsupported one."""
    name = os.name.lower()
    arch = os.arch.lower()
    if name.startswith("linux"):
        os_part = "linux"
    elif name.startswith("mac") or name.startswith("darwin"):
        os_part = "macos"
    elif name.startswith("windows"):
        os_part = "windows"
    else:
        os_part = name
    if arch in ("amd64", "x86_64"):
        arch_part = "x64"
    elif arch in ("aarch64", "arm64"):
        arch_part = "arm64"
    else:
        arch_part = arch
    key = os_part + "-" + arch_part
    if key not in _YQ_BINARIES:
        fail("reading pubspec files needs yq %s, which rules_dart pins for %s only; there is none for this fetch host (os %r, arch %r)" % (
            YQ_VERSION,
            ", ".join(sorted(_YQ_BINARIES.keys())),
            os.name,
            os.arch,
        ))
    return key

def _executable_name(os):
    return "yq.exe" if os.name.lower().startswith("windows") else "yq"

def _yq_repository_impl(rctx):
    asset, sha256 = _YQ_BINARIES[_host_key(rctx.os)]
    exe = _executable_name(rctx.os)
    pinned_download(
        rctx,
        url = _YQ_URL.format(version = YQ_VERSION, asset = asset),
        output = exe,
        sha256 = sha256,
        executable = True,
    )
    rctx.file("BUILD.bazel", 'exports_files(["%s"])\n' % exe)

yq_repository = repository_rule(
    implementation = _yq_repository_impl,
    doc = "Downloads the pinned `yq` binary for the fetch host, checked against its published sha256.",
)

def _yq_path(ctx):
    """Resolves the `yq` binary through this module's repo mapping."""
    return ctx.path(Label("@dart_yq//:" + _executable_name(ctx.os)))

def _document_error(name, docs):
    """Returns why a file's documents are not one mapping, or None."""
    if len(docs) > 1:
        return "%s: holds %d YAML documents; it must hold one" % (name, len(docs))
    for doc in docs:
        if doc["duplicate_keys"]:
            return "%s: a mapping repeats a key; YAML forbids duplicate keys" % name
        data = doc["data"]
        if data != None and type(data) != "dict":
            return "%s: expected a mapping at the top level, got a %s" % (name, "list" if type(data) == "list" else "scalar")
    return None

def yaml_to_json_or_error(ctx, paths, names = None):
    """Converts YAML files to decoded data in one `yq` process.

    Args:
      ctx: A module extension or repository rule context.
      paths: The files: strings, paths or Labels `ctx.path` accepts. The
        caller watches them if it needs to; a file read here is not watched.
      names: Names for diagnostics, one per path; defaults to the paths.

    Returns:
      struct(data, error): `data` is one top-level mapping per path, in
      order (`{}` for an empty or comment-only file), and `error` is None;
      or `data` is None and `error` names the first file that is not valid
      YAML, repeats a key, holds more than one document or has no mapping
      at the top level.
    """
    if not paths:
        return struct(data = [], error = None)
    absolute = [str(ctx.path(p)) for p in paths]
    shown = names if names != None else [str(p) for p in paths]
    unique = {path: True for path in absolute}.keys()
    result = ctx.execute([_yq_path(ctx)] + _FLAGS + [_EXPRESSION] + unique)
    if result.return_code != 0:
        message = result.stderr.strip() or result.stdout.strip()
        for i in range(len(absolute)):
            message = message.replace(absolute[i], shown[i])
        return struct(data = None, error = "cannot read YAML: " + message)
    docs = {path: [] for path in unique}
    for line in result.stdout.splitlines():
        if line.strip() == "":
            continue
        doc = json.decode(line)
        docs[doc["file"]].append(doc)
    data = []
    for i in range(len(absolute)):
        file_docs = docs[absolute[i]]
        err = _document_error(shown[i], file_docs)
        if err != None:
            return struct(data = None, error = err)
        value = file_docs[0]["data"] if file_docs else None
        data.append(value if value != None else {})
    return struct(data = data, error = None)

def yaml_to_json(ctx, paths, names = None):
    """Converts YAML files to their top-level mappings in one `yq` process.

    Fails naming the file on anything `yaml_to_json_or_error` reports.

    Args:
      ctx: A module extension or repository rule context.
      paths: The files: strings, paths or Labels `ctx.path` accepts.
      names: Names for diagnostics, one per path; defaults to the paths.

    Returns:
      One top-level mapping per path, in order.
    """
    result = yaml_to_json_or_error(ctx, paths, names)
    if result.error != None:
        fail(result.error)
    return result.data
