#!/usr/bin/env bash
#
# Prepares the release of one module of this repository: the archive of the
# module, its docs archive, and the release notes on standard output.
#
# bazel-contrib's reusable release workflow runs this script at the repository
# root, with the checked-out tag as its argument, and a hard-coded path. The
# tag says which module it is: rules_dart-v0.29.0 or rules_flutter-v0.30.3.
#
#   rules_<module>-v<version>.tar.gz       the module only (`git archive` of the
#                                          tag, run in rules_<module>/), under
#                                          the prefix rules_<module>-<version>/
#   rules_<module>-v<version>.docs.tar.gz  the generated API docs
#   rules_<module>-v<version>-tools-<sdk>-<platform>.tar.gz
#                                          the prebuilt tools of one platform,
#                                          built by the release's `tools` job
#   rules_dart-v<version>-pub_scanner-<platform>.tar.gz
#                                          the pub archive scanner of one
#                                          platform, built by the same job
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
# Where the release's files are downloaded from. RELEASE_DOWNLOAD replaces it
# in a rehearsal (a `file://` directory holding the files of an earlier run).
DOWNLOAD="${RELEASE_DOWNLOAD:-https://github.com/${REPO}/releases/download}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The sha256 SRI integrity Bazel verifies for an archive_override.
integrity_of() {
  echo "sha256-$(openssl dgst -sha256 -binary "$1" | openssl base64 -A)"
}

# The archive. The prefix is what GitHub's own source archives use, so a
# consumer can switch from this artifact to a source archive with the same
# strip_prefix. `gzip -n` drops the file name and time from the header, and
# every entry has the time of the tagged commit: the same tag always yields the
# same bytes, and the same sha256.
# Run inside the module's directory, `git archive <tag>` archives that
# directory alone, with paths relative to it. It is not `<tag>:<module>`: the
# tree of a directory is not a commit, and `export-subst` (the stamp in
# rules_dart/BUILD.bazel) expands only for a commit.
# NB: what is left out of the archive is configured in <module>/.gitattributes.
git rev-parse --verify --quiet "${TAG}:${MODULE}" >/dev/null ||
  die "tag ${TAG} has no ${MODULE}/ directory"

# The prebuilt tools (`<module>/<table>`, see
# rules_dart/dart/private/prebuilt_tools.bzl). The release workflow's `tools`
# jobs leave one artifact per platform, which the reusable workflow downloads
# into prebuilt-tools-<module>-<platform>/ here; RELEASE_TOOLS names another
# directory holding them. `release tools table` checks each archive against
# its sidecar, copies it to $OUT under its release name (matched by
# `release_files`) and writes the table, which the archive holds in place of
# the checkout's empty one (export-ignore). A platform without an archive is absent from
# the table: there, the module builds its tools from source.
TOOLS="$ROOT/rules_dart/tools"
quiet=(--ui_event_filters=-info --noshow_progress --show_result=0)
case "$MODULE" in
  rules_dart) TABLE_PATH=dart/private/prebuilt_tools.json ;;
  rules_flutter) TABLE_PATH=flutter/private/prebuilt_tools.json ;;
esac
TOOLS_IN="$TMP/prebuilt_tools_in"
mkdir -p "$TOOLS_IN"
for dir in "${RELEASE_TOOLS:-$ROOT}"/prebuilt-tools-"${MODULE}"-*/; do
  [[ -d "$dir" ]] && cp -R "$dir" "$TOOLS_IN/"
done
TOOLS_NOTE="$(cd "$TOOLS" && bazel run "${quiet[@]}" //release:release -- tools table \
  --module="$MODULE" --tag="$TAG" --artifacts="$TOOLS_IN" --out="$OUT" \
  --table="$TMP/prebuilt_tools.json" --download="$DOWNLOAD")" ||
  die "the prebuilt tools of ${TAG} do not match their sidecars"
[[ -s "$TMP/prebuilt_tools.json" ]] || die "release tools table wrote no table"
# The table goes in after `git archive`, as one more entry with the commit's
# time, mode and owner the archive's own files have: `--add-virtual-file`
# puts the path of a subdirectory run in front of a virtual file's path.
(cd "$ROOT/$MODULE" && git archive --format=tar --prefix="${PREFIX}/" "$TAG") >"$TMP/module.tar"
STAGE="$TMP/table_stage"
mkdir -p "$STAGE/${PREFIX}/$(dirname "$TABLE_PATH")"
cp "$TMP/prebuilt_tools.json" "$STAGE/${PREFIX}/${TABLE_PATH}"
tar --append --file="$TMP/module.tar" --directory="$STAGE" --format=ustar \
  --owner=0 --group=0 --numeric-owner --mode=0664 \
  --mtime="@$(git log -1 --format=%ct "${TAG}^{commit}")" "${PREFIX}/${TABLE_PATH}"
gzip -n <"$TMP/module.tar" >"$OUT/$ARCHIVE"
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
#
# One download, with the patience a shared runner's network needs. A refusal
# that may pass (a transport error, 403, 408, 429, a 5xx) is tried again after
# 5, 15 and 45 seconds; anything else (404) stops at once. Each try is bounded
# (20 s to connect, 120 s in all), so four tries take well under ten minutes.
# RELEASE_PREP_FETCH_ATTEMPTS and RELEASE_PREP_FETCH_DELAY change the count and
# the first delay (the tests set it to 0).
#
# The token of GH_TOKEN or GITHUB_TOKEN is sent as `Authorization: Bearer`
# only to api.github.com/repos/<this repository>/ and to this repository's
# release assets (curl drops the header when a redirect leaves the host), in a
# curl config read from standard input: it is on no command line, and `set -x`
# is switched off around it. The release job of bazel-contrib's reusable
# workflow sets neither variable, so there the calls are anonymous (60 an hour
# per address): when GitHub refuses with its rate limit, a retry within
# minutes cannot help and the message says so.
fetch() {
  # Before the token is read: a trace shows every assignment.
  local traced=0
  case $- in *x*)
    traced=1
    set +x
    ;;
  esac
  local url="$1" out="$2" token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local attempts="${RELEASE_PREP_FETCH_ATTEMPTS:-4}" delay="${RELEASE_PREP_FETCH_DELAY:-5}"
  local hdr="$TMP/fetch.headers" n=1 code rc use_token=0
  case "$url" in
    "https://api.github.com/repos/${REPO}/"* | "https://github.com/${REPO}/releases/download/"*)
      [[ -n "$token" ]] && use_token=1 ;;
  esac
  while :; do
    rc=0
    : >"$hdr"
    if [[ "$use_token" == 1 ]]; then
      code="$(curl --silent --show-error --location --connect-timeout 20 --max-time 120 \
        --dump-header "$hdr" --output "$out" --write-out '%{http_code}' --config - "$url" \
        <<<"header = \"Authorization: Bearer ${token}\"")" || rc=$?
    else
      code="$(curl --silent --show-error --location --connect-timeout 20 --max-time 120 \
        --dump-header "$hdr" --output "$out" --write-out '%{http_code}' "$url")" || rc=$?
    fi
    if [[ "$rc" == 0 && ("$code" == 2?? || "$url" == file://*) ]]; then
      [[ "$traced" == 1 ]] && set -x
      return 0
    fi
    rm -f "$out"
    if [[ "$rc" == 0 && "$code" =~ ^(400|401|404|405|410|422)$ ]]; then break; fi
    if [[ "$n" -ge "$attempts" ]]; then break; fi
    echo "release_prep: ${url} answered ${code} (curl exit ${rc}); attempt ${n} of ${attempts}, trying again" >&2
    sleep $((delay * 3 ** (n - 1)))
    n=$((n + 1))
  done
  echo "release_prep: ${url} answered ${code} (curl exit ${rc}) after ${n} attempt(s)" >&2
  if grep -qi '^x-ratelimit-remaining: *0' "$hdr" 2>/dev/null; then
    echo "release_prep: GitHub's API rate limit for this address is used up (resets at epoch $(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *//p' "$hdr" | tr -d '\r'))" >&2
  fi
  [[ "$traced" == 1 ]] && set -x
  return 1
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
printf '%s\n\n' "$TOOLS_NOTE"
# git-cliff comes from rules_multitool in the tools/ module of rules_dart; the
# work directory is the repository, the configuration the module's own.
(cd "$TOOLS" && bazel run "${quiet[@]}" @multitool//tools/git-cliff -- \
  --workdir "$ROOT" --config "$ROOT/$MODULE/cliff.toml" --strip header "${BASE}..${TAG}")
