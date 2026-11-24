#!/usr/bin/env bash
#
# Prepares the release of one module of this repository: the archive of the
# module, its docs archive, and the release notes on standard output.
#
# bazel-contrib's reusable release workflow runs this script at the repository
# root, with the checked-out tag as its argument, and a hard-coded path. The
# tag says which module it is: rules_dart-v0.29.0 or rules_flutter-v0.30.3.
#
#   rules_<module>-v<version>.tar.gz       the module only, `git archive` of
#                                          <tag>:rules_<module>, under the
#                                          prefix rules_<module>-<version>/
#   rules_<module>-v<version>.docs.tar.gz  the generated API docs
#
# Both are written to $RELEASE_OUT (default: the current directory). What
# `export-ignore` in the module's .gitattributes removes is not in the
# archive.
set -o errexit -o nounset -o pipefail

die() {
  echo "release_prep: $*" >&2
  exit 1
}

TAG="${1:-}"
[[ -n "$TAG" ]] || die "tag argument is required"
if [[ "$TAG" =~ ^(rules_dart|rules_flutter)-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  MODULE="${BASH_REMATCH[1]}"
  VERSION="${BASH_REMATCH[2]}"
else
  die "tag '$TAG' is not rules_dart-vX.Y.Z or rules_flutter-vX.Y.Z"
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
OUT="${RELEASE_OUT:-$PWD}"
REPO="${GITHUB_REPOSITORY:-Mivr/ai_rules_dart}"
PREFIX="${MODULE}-${VERSION}"
ARCHIVE="${MODULE}-v${VERSION}.tar.gz"
DOCS_ARCHIVE="${MODULE}-v${VERSION}.docs.tar.gz"
DOWNLOAD="https://github.com/${REPO}/releases/download"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The sha256 SRI integrity Bazel verifies for an archive_override.
integrity_of() {
  echo "sha256-$(openssl dgst -sha256 -binary "$1" | openssl base64 -A)"
}

# The archive. The prefix is what GitHub's own source archives use, so a
# consumer can switch from this artifact to a source archive with the same
# strip_prefix. `gzip -n` drops the file name and time from the header: the
# same tag always yields the same bytes, and the same sha256.
# NB: what is left out of the archive is configured in <module>/.gitattributes.
git rev-parse --verify --quiet "${TAG}:${MODULE}" >/dev/null ||
  die "tag ${TAG} has no ${MODULE}/ directory"
# The tree of a directory has no time of its own, so every entry gets the time
# of the tagged commit (`--mtime`, git 2.39).
git archive --format=tar --mtime="$(git log -1 --format=%cI "${TAG}^{commit}")" \
  --prefix="${PREFIX}/" "${TAG}:${MODULE}" | gzip -n >"$OUT/$ARCHIVE"
INTEGRITY="$(integrity_of "$OUT/$ARCHIVE")"

# What a consumer pastes into MODULE.bazel. Neither module is on the Bazel
# Central Registry unless a registry entry has been merged, so the archive
# itself is named: every byte is verified against the integrity below.
snippet_dart() {
  cat <<EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "ai_rules_dart", version = "${VERSION}", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_dart",
    urls = ["${DOWNLOAD}/${TAG}/${ARCHIVE}"],
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}",
)
\`\`\`
EOF
}

# rules_flutter needs the rules_dart release its MODULE.bazel names as its
# floor, so the consumer gets that archive too. Its integrity is computed from
# the bytes downloaded, after they match the digest GitHub recorded for the
# release asset.
fetch() {
  curl --fail --show-error --location --silent --output "$2" "$1"
}

snippet_flutter() {
  local floor dart_tag dart_archive dart_prefix hex digest
  floor="$(git show "${TAG}:${MODULE}/MODULE.bazel" |
    sed -n 's/^bazel_dep(name = "ai_rules_dart", version = "\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$floor" ]] || die "no ai_rules_dart bazel_dep in ${TAG}:${MODULE}/MODULE.bazel"
  dart_tag="rules_dart-v${floor}"
  dart_archive="${dart_tag}.tar.gz"
  dart_prefix="rules_dart-${floor}"
  fetch "${DOWNLOAD}/${dart_tag}/${dart_archive}" "$TMP/$dart_archive" ||
    die "cannot download ${DOWNLOAD}/${dart_tag}/${dart_archive}: release rules_dart ${floor} first"
  fetch "https://api.github.com/repos/${REPO}/releases/tags/${dart_tag}" "$TMP/dart_release.json" ||
    die "cannot read the release ${dart_tag} from the GitHub API"
  digest="$(jq -r --arg name "$dart_archive" \
    '[.assets[]? | select(.name == $name) | .digest][0] // empty' "$TMP/dart_release.json")" ||
    die "cannot parse the release ${dart_tag}"
  [[ -n "$digest" ]] || die "release ${dart_tag} records no digest for ${dart_archive}"
  hex="$(openssl dgst -sha256 "$TMP/$dart_archive" | awk '{print $NF}')"
  [[ "$digest" == "sha256:${hex}" ]] ||
    die "${dart_archive} sha256 ${hex} does not match release digest ${digest}"
  cat <<EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "ai_rules_flutter", version = "${VERSION}", repo_name = "rules_flutter")
bazel_dep(name = "ai_rules_dart", version = "${floor}", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_flutter",
    urls = ["${DOWNLOAD}/${TAG}/${ARCHIVE}"],
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}",
)

archive_override(
    module_name = "ai_rules_dart",
    urls = ["${DOWNLOAD}/${dart_tag}/${dart_archive}"],
    integrity = "$(integrity_of "$TMP/$dart_archive")",
    strip_prefix = "${dart_prefix}",
)
\`\`\`
EOF
}

# The tags that have a published (not draft) release. A tag the release gate
# refused stays in git but has no release, so "the previous release" is not
# "the previous tag". There is no fallback to the whole history.
PUBLISHED="$TMP/published"
: >"$PUBLISHED"
PER_PAGE="${RELEASE_PREP_PER_PAGE:-100}"
for page in $(seq 1 50); do
  url="https://api.github.com/repos/${REPO}/releases?per_page=${PER_PAGE}&page=${page}"
  fetch "$url" "$TMP/releases_${page}.json" ||
    die "request to GitHub releases API failed for $url"
  jq -e 'type == "array"' "$TMP/releases_${page}.json" >/dev/null 2>&1 ||
    die "could not parse GitHub releases response for $url"
  jq -r '.[] | select(.draft == false) | .tag_name' "$TMP/releases_${page}.json" >>"$PUBLISHED"
  [[ "$(jq 'length' "$TMP/releases_${page}.json")" -ge "$PER_PAGE" ]] || break
done

# What the consumer pastes; any failure here stops before the slow work.
if [[ "$MODULE" == rules_dart ]]; then
  SNIPPET="$(snippet_dart)"
else
  SNIPPET="$(snippet_flutter)"
fi

# The notes are the `Changelog:` trailers of the commits that touch the
# module, from the newest published release of the module (or, for a module
# with none here, the commit of its last release before it moved) to the tag
# (see AGENTS.md). The release job checks out the tag alone, so fetch the
# history and the tags first.
fetch_args=(--tags)
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  fetch_args+=(--unshallow)
fi
git fetch "${fetch_args[@]}" origin || die "git fetch --tags failed"

TOOLS="$ROOT/rules_dart/tools"
quiet=(--ui_event_filters=-info --noshow_progress --show_result=0)
BASE="$(cd "$TOOLS" && bazel run "${quiet[@]}" //release:release -- base \
  --module="$MODULE" --tag="$TAG" --published="$PUBLISHED")" ||
  die "cannot find where the notes of ${TAG} start"
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null ||
  die "the notes of ${TAG} start at ${BASE}, which is not in the repository history"
# The generated API docs, for the registry, see
# https://github.com/bazelbuild/bazel-central-registry/issues/5593
DOCS_BASE="$TMP/docs"
bazel_docs() { (cd "$ROOT/$MODULE" && bazel --output_base="$DOCS_BASE" "$@"); }
bazel_docs query --output=label --output_file="$TMP/doc_targets" 'kind("starlark_doc_extract rule", //...)' >&2
[[ -s "$TMP/doc_targets" ]] || die "no starlark_doc_extract target found in ${MODULE}"
bazel_docs build --target_pattern_file="$TMP/doc_targets" >&2
DOCS_BIN="$(bazel_docs info bazel-bin)"
tar --create --auto-compress --directory "$DOCS_BIN" --file "$OUT/$DOCS_ARCHIVE" .
bazel_docs shutdown >/dev/null 2>&1 || true
[[ -s "$OUT/$DOCS_ARCHIVE" ]] || die "the docs archive ${DOCS_ARCHIVE} is empty"

printf '%s\n\n' "$SNIPPET"
# git-cliff comes from rules_multitool in the tools/ module of rules_dart; the
# work directory is the repository, the configuration the module's own.
(cd "$TOOLS" && bazel run "${quiet[@]}" @multitool//tools/git-cliff -- \
  --workdir "$ROOT" --config "$ROOT/$MODULE/cliff.toml" --strip header "${BASE}..${TAG}")
