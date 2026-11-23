#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG=$1
VERSION=${TAG:1}
# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_flutter-${VERSION}"
ARCHIVE="rules_flutter-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix="${PREFIX}"/ "${TAG}" | gzip >"$ARCHIVE"

# The release workflow sets no GH_TOKEN, so read release metadata through the
# public REST API. The token, when present, travels in a curl config on
# stdin, never on a command line. The shell never expands it, so even
# `set -x` cannot show it; python3 reads it straight from the environment.
# github_api_get <url> <output file>
github_api_get() {
  python3 - <<'PY' | curl --fail --show-error --location -K - --output "$2" "$1"
import os
for _var in ("GH_TOKEN", "GITHUB_TOKEN", "BAZELISK_GITHUB_TOKEN"):
    _token = os.environ.get(_var)
    if _token:
        _token = _token.replace("\\", "\\\\").replace('"', '\\"')
        print('header = "Authorization: Bearer ' + _token + '"')
        break
PY
}

# The newest tag with a published, non-draft GitHub release that is older than
# the tag being released. Tags that were refused by the release gate stay in git
# but have no release, so the previous *tag* is not the previous release.
# release_base_tag <tag> <scratch dir>: prints the tag, or a release_prep: message.
release_base_tag() {
  local tag=$1 dir=$2 page url
  for page in $(seq 1 20); do
    url="${FLUTTER_API_URL}?per_page=100&page=${page}"
    if ! github_api_get "$url" "$dir/releases_${page}.json"; then
      echo "release_prep: failed to fetch the published releases from ${url}" >&2
      return 1
    fi
    local rc=0
    python3 - "$tag" "$page" "$dir" <<'PY' || rc=$?
import json
import re
import sys
tag, pages, directory = sys.argv[1], int(sys.argv[2]), sys.argv[3]
SEMVER = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)$")
mine = SEMVER.match(tag)
if not mine:
    print(f"release_prep: tag {tag} is not of the form vMAJOR.MINOR.PATCH", file=sys.stderr)
    sys.exit(1)
limit = tuple(int(n) for n in mine.groups())
best = None
last_len = 0
for number in range(1, pages + 1):
    path = f"{directory}/releases_{number}.json"
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"release_prep: cannot parse the published releases {path}: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, list):
        print(f"release_prep: the published releases {path} are not a JSON list", file=sys.stderr)
        sys.exit(1)
    last_len = len(data)
    for release in data:
        if not isinstance(release, dict) or release.get("draft") is not False:
            continue
        found = SEMVER.match(str(release.get("tag_name")))
        if not found:
            continue
        version = tuple(int(n) for n in found.groups())
        if version < limit and (best is None or version > best[0]):
            best = (version, release["tag_name"])
if best:
    print(best[1], end="")
    sys.exit(0)
if last_len >= 100:
    sys.exit(3)
print(f"release_prep: no published release older than {tag} exists", file=sys.stderr)
sys.exit(1)
PY
    case $rc in
      0) return 0 ;;
      3) ;;
      *) return 1 ;;
    esac
  done
  echo "release_prep: no published release older than ${tag} within ${page} pages of releases" >&2
  return 1
}

# The sha256 SRI integrity of a file, for an `archive_override` block.
sri_of() {
  python3 -c 'import base64, hashlib, sys; print("sha256-" + base64.b64encode(hashlib.sha256(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

FLUTTER_INTEGRITY=$(sri_of "$ARCHIVE")
FLUTTER_URL="https://github.com/Mivr/ai_rules_flutter/releases/download/${TAG}/rules_flutter-${TAG}.tar.gz"

# Neither module is on the Bazel Central Registry, so consumers need the
# `archive_override` for `ai_rules_dart` too. The version comes from the
# tagged MODULE.bazel, and the integrity from that release's own archive,
# verified against the release digest before anything is printed.
DART_VERSION=$(git show "${TAG}:MODULE.bazel" | sed -n 's/^bazel_dep(name = "ai_rules_dart", version = "\([^"]*\)".*/\1/p')
if [[ -z "$DART_VERSION" ]]; then
  echo "release_prep: no ai_rules_dart bazel_dep in ${TAG}:MODULE.bazel" >&2
  exit 1
fi
DART_TAG="v${DART_VERSION}"
DART_ARCHIVE="rules_dart-${DART_TAG}.tar.gz"
DART_URL="https://github.com/Mivr/ai_rules_dart/releases/download/${DART_TAG}/${DART_ARCHIVE}"
DART_PREFIX="rules_dart-${DART_VERSION}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# The notes start at the newest published release; fail before any slow work if
# it cannot be found. There is deliberately no fallback to the previous tag.
FLUTTER_API_URL="https://api.github.com/repos/Mivr/ai_rules_flutter/releases"
if ! BASE_TAG=$(release_base_tag "$TAG" "$TMPDIR"); then
  exit 1
fi
curl --fail --show-error --location --output "$TMPDIR/$DART_ARCHIVE" "$DART_URL"
DART_HEX=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TMPDIR/$DART_ARCHIVE")
API_URL="https://api.github.com/repos/Mivr/ai_rules_dart/releases/tags/${DART_TAG}"
RELEASE_JSON="$TMPDIR/release.json"
if ! github_api_get "$API_URL" "$RELEASE_JSON"; then
  echo "release_prep: failed to fetch release metadata for ${DART_TAG} from ${API_URL}" >&2
  exit 1
fi
if ! EXPECTED_DIGEST=$(python3 - "$RELEASE_JSON" "$DART_ARCHIVE" <<'PY'
import json
import sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    print(f"release_prep: cannot parse release metadata {path}: {e}", file=sys.stderr)
    sys.exit(1)
assets = data.get("assets") if isinstance(data, dict) else None
if not isinstance(assets, list):
    print(f"release_prep: release metadata {path} has no 'assets' list", file=sys.stderr)
    sys.exit(1)
for asset in assets:
    if isinstance(asset, dict) and asset.get("name") == want:
        digest = asset.get("digest")
        if not digest:
            print(f"release_prep: asset {want} has no digest in release metadata {path}", file=sys.stderr)
            sys.exit(1)
        print(digest, end="")
        sys.exit(0)
print(f"release_prep: no asset named {want} in release metadata {path}", file=sys.stderr)
sys.exit(1)
PY
); then
  exit 1
fi
if [[ "$EXPECTED_DIGEST" != "sha256:${DART_HEX}" ]]; then
  echo "release_prep: ${DART_ARCHIVE} sha256 ${DART_HEX} does not match release digest ${EXPECTED_DIGEST}" >&2
  exit 1
fi
DART_INTEGRITY=$(sri_of "$TMPDIR/$DART_ARCHIVE")

DOCS_DIR="$TMPDIR/docs"
TARGETS_FILE="$TMPDIR/doc_targets"
DOCS_QUERY='kind("starlark_doc_extract rule", //...)'
bazel --output_base="$DOCS_DIR" query --output=label --output_file="$TARGETS_FILE" "$DOCS_QUERY"
if [[ ! -s "$TARGETS_FILE" ]]; then
  bazel --output_base="$DOCS_DIR" shutdown >/dev/null 2>&1 || true
  echo "release_prep: query '${DOCS_QUERY}' found no targets" >&2
  exit 1
fi
bazel --output_base="$DOCS_DIR" build --target_pattern_file="$TARGETS_FILE"
DOCS_BIN=$(bazel --output_base="$DOCS_DIR" info bazel-bin)
DOCS_ARCHIVE="${ARCHIVE%.tar.gz}.docs.tar.gz"
tar --create --auto-compress --directory "$DOCS_BIN" --file "$DOCS_ARCHIVE" .
bazel --output_base="$DOCS_DIR" shutdown >/dev/null 2>&1 || true
# List into a file: under pipefail, `tar --list | grep -q` fails when grep exits
# on its first match and tar hits EPIPE on a long listing.
DOCS_LIST="$TMPDIR/docs_list"
if [[ ! -s "$DOCS_ARCHIVE" ]] || ! tar --list --file "$DOCS_ARCHIVE" >"$DOCS_LIST" ||
  ! grep -q '\.binaryproto$' "$DOCS_LIST"; then
  echo "release_prep: query '${DOCS_QUERY}' produced empty or missing archive ${DOCS_ARCHIVE}" >&2
  exit 1
fi

cat <<EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "ai_rules_flutter", version = "${VERSION}", repo_name = "rules_flutter")
bazel_dep(name = "ai_rules_dart", version = "${DART_VERSION}", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_flutter",
    urls = ["${FLUTTER_URL}"],
    integrity = "${FLUTTER_INTEGRITY}",
    strip_prefix = "${PREFIX}",
)

archive_override(
    module_name = "ai_rules_dart",
    urls = ["${DART_URL}"],
    integrity = "${DART_INTEGRITY}",
    strip_prefix = "${DART_PREFIX}",
)
\`\`\`
EOF

# The notes are the `Changelog:` trailers since the newest published release
# (see AGENTS.md), not since the previous tag: a tag the release gate refused
# stays in git. The release job checks out the tag alone, so fetch the history
# back to that release first.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --quiet --unshallow --tags origin
fi
if ! git rev-parse --verify --quiet "refs/tags/${BASE_TAG}^{commit}" >/dev/null; then
  echo "release_prep: published release tag ${BASE_TAG} is not in the repository history" >&2
  exit 1
fi
echo
bazel run --noshow_progress --ui_event_filters=-info \
  @multitool//tools/git-cliff:workspace_root -- \
  --config cliff.toml --strip header "${BASE_TAG}..${TAG}"
