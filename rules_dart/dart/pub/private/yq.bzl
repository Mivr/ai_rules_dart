"""YAML files read as JSON: a pinned `yaml2json` binary converts them, Starlark decodes.

`pubspec.lock`, `pubspec.yaml` and `pubspec_overrides.yaml` are YAML. Instead
of parsing YAML in Starlark, the rules run one pinned `yaml2json --batch`
process over every file a step needs and read its JSON output with
`json.decode`.

The binary comes from `yq_repository`, a repository rule that downloads the
release asset for the fetch host and checks its published sha256. The `dart`
module extension instantiates it once as `@dart_yq`, and `yaml_to_json`
addresses it through this module's own repo mapping, so it works from any
module extension or repository rule whatever name a consumer gives this
module.

The conversion keeps booleans as JSON booleans, `null`, `~` and empty values
as JSON null, and every other scalar as a string holding its source text, so
`1.10` stays `"1.10"` and a digit-only checksum keeps its digits. It reports
duplicate mapping keys (which `json.decode` would resolve silently to the
last one). The checks that `package:yaml` and `pub` make and the converter
does not are made here, naming the file: no duplicate keys, at most one
document, and a mapping at the top level.
An empty or comment-only file reads as an empty mapping. A merge key `<<` stays
a literal key, as in `package:yaml`; the converter fails, naming the file and
line, on what `package:yaml` also refuses (a tab used as indentation or after
`:` or `-`, text after `...` or after a closing quote).

Everything that decides what a file decodes to lives in this file (the
`yaml2json` release, its checksums, its flags and these checks), so the pub
extension's facts key covers it by digesting this file's bytes.
"""

load("//dart/private:download.bzl", "pinned_download")

visibility(["//dart/..."])

YQ_VERSION = "1.2.0"

_YQ_URL = "https://github.com/SimpleSoftwareOrg/yaml2json/releases/download/v{version}/{asset}"

# Release asset and sha256 of the raw binary for every supported fetch host.
# The checksums are the release's published `checksums.txt` (sha256).
_YQ_BINARIES = {
    "linux-arm64": ("yaml2json-linux-arm64", "3990677cf94789ae2537b14967899a3f4095df10570687be56aadb16aba83497"),
    "linux-x64": ("yaml2json-linux-x86_64", "531e6928aaecd17935a52c756e99ec432ae91245f7e3c0df3abbaa6898d572d2"),
    "macos-arm64": ("yaml2json-macos-arm64", "987ff149c18b088b606333141a4e2f17d6a50a417e563518248abf47334c2c4c"),
    "macos-x64": ("yaml2json-macos-x86_64", "05a336c45e0a30b588bc743173c3dee87ff7164701958c5232f230974190205f"),
    "windows-x64": ("yaml2json-windows-x86_64.exe", "84f2b24a107728e627187e03fa11f0d2394b466b06e96b4c29d05bcbdbe5138d"),
}

# One JSON line per document of every file: the file as named on the command
# line, the document's index in it, whether any mapping in it repeats a key,
# and the data. Booleans and nulls keep their type; every other scalar becomes
# a string holding its source text.
_FLAGS = ["--batch"]

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
        fail("reading pubspec files needs yaml2json %s, which rules_dart pins for %s only; there is none for this fetch host (os %r, arch %r)" % (
            YQ_VERSION,
            ", ".join(sorted(_YQ_BINARIES.keys())),
            os.name,
            os.arch,
        ))
    return key

def _executable_name(os):
    return "yaml2json.exe" if os.name.lower().startswith("windows") else "yaml2json"

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
    doc = "Downloads the pinned `yaml2json` binary for the fetch host, checked against its published sha256.",
)

def _yq_path(ctx):
    """Resolves the `yaml2json` binary through this module's repo mapping."""
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
    """Converts YAML files to decoded data in one `yaml2json` process.

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
    result = ctx.execute([_yq_path(ctx)] + _FLAGS + unique)
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
    """Converts YAML files to their top-level mappings in one `yaml2json` process.

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
