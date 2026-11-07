#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "release_prep: tag argument is required" >&2
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release_prep: tag '$TAG' is not a valid semver tag (v<major>.<minor>.<patch>)" >&2
  exit 1
fi

# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_dart-${TAG:1}"
ARCHIVE="rules_dart-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
# `gzip -n`: no filename or timestamp in the header, so the same tag always
# yields the same archive bytes (and the same sha256).
git archive --format=tar --prefix=${PREFIX}/ ${TAG} | gzip -n > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')
# SRI integrity for the `archive_override` snippet below: the base64 sha256
# Bazel verifies on download. It is computed from the archive just built, so
# the printed URL, integrity and strip_prefix always describe this release.
INTEGRITY="sha256-$(openssl dgst -sha256 -binary "$ARCHIVE" | openssl base64 -A)"

# Add generated API docs to the release, see https://github.com/bazelbuild/bazel-central-registry/issues/5593
docs="$(mktemp -d)"; targets="$(mktemp)"
bazel --output_base="$docs" query --output=label --output_file="$targets" 'kind("starlark_doc_extract rule", //...)'
bazel --output_base="$docs" build --target_pattern_file="$targets"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
tar --create --auto-compress \
    --directory "$(bazel --output_base="$docs" info bazel-bin)" \
    --file "$GITHUB_WORKSPACE/${ARCHIVE%.tar.gz}.docs.tar.gz" .

cat << EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "ai_rules_dart", version = "${TAG:1}", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/ai_rules_dart/releases/download/${TAG}/${ARCHIVE}"],
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}",
)
\`\`\`
EOF

# Release notes from the `Changelog:` trailers since the newest published release.
# The reusable workflow checks out only the tagged commit, without other tags.
git fetch --quiet --tags --unshallow origin 2>/dev/null || git fetch --quiet --tags origin 2>/dev/null || true

REPO="${REPO:-Mivr/ai_rules_dart}"

BASE_TAG=""
PAGE=1
PREV_PAGE_BODY=""
SAME_PAGE_COUNT=0

while [ -z "$BASE_TAG" ]; do
  API_URL="https://api.github.com/repos/${REPO}/releases?per_page=100&page=${PAGE}"
  if ! PAGE_BODY=$(curl --fail --show-error --location -s "$API_URL"); then
    echo "release_prep: request to GitHub releases API failed for $API_URL" >&2
    exit 1
  fi

  # Stop if an unpaginated test stub repeats the same page body indefinitely,
  # while still allowing multi-page fixtures with repeated intermediate pages.
  if [ "$PAGE" -gt 1 ] && [ "$PAGE_BODY" = "$PREV_PAGE_BODY" ]; then
    SAME_PAGE_COUNT=$((SAME_PAGE_COUNT + 1))
    if [ "$SAME_PAGE_COUNT" -ge 5 ]; then
      break
    fi
  else
    SAME_PAGE_COUNT=0
  fi
  PREV_PAGE_BODY="$PAGE_BODY"

  PARSER_RC=0
  PARSER_OUTPUT=$(python3 -c '
import json, re, sys

semver = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)")
tm = semver.fullmatch(sys.argv[1])
if not tm:
    sys.exit(3)
target = tuple(map(int, tm.groups()))

try:
    releases = json.load(sys.stdin)
except ValueError:
    sys.exit(3)

if not isinstance(releases, list):
    sys.exit(3)

if len(releases) == 0:
    sys.exit(4)

candidates = []
for r in releases:
    if not isinstance(r, dict):
        sys.exit(3)
    draft = r.get("draft", False)
    if draft is not False and draft is not None:
        continue
    cand_tag = r.get("tag_name")
    if not isinstance(cand_tag, str):
        continue
    cm = semver.fullmatch(cand_tag)
    if not cm:
        continue
    cand = tuple(map(int, cm.groups()))
    if cand < target:
        candidates.append((cand, cand_tag))

if candidates:
    # Pick the newest published release older than the target
    newest = max(candidates, key=lambda c: c[0])
    print(newest[1])
    sys.exit(0)

sys.exit(2)
' "$TAG" <<<"$PAGE_BODY") || PARSER_RC=$?

  case "$PARSER_RC" in
    0)
      BASE_TAG="$PARSER_OUTPUT"
      ;;
    2)
      PAGE=$((PAGE + 1))
      if [ "$PAGE" -gt 50 ]; then
        break
      fi
      ;;
    4)
      break
      ;;
    *)
      echo "release_prep: could not parse GitHub releases response" >&2
      exit 1
      ;;
  esac
done

if [ -z "$BASE_TAG" ]; then
  echo "release_prep: no earlier published release found for $TAG" >&2
  exit 1
fi

echo
# git-cliff is provided by rules_multitool, which now lives in the tools/
# module (tools/MODULE.bazel): the root module has no `@multitool` repo, so
# run it from tools/ with --workdir pointing back at the repo root. Same
# flags and tag range as before, so the notes are unchanged in content.
ROOT="$PWD"
(cd tools && bazel run @multitool//tools/git-cliff -- \
    --workdir "$ROOT" --config "$ROOT/cliff.toml" --strip header "${BASE_TAG}..${TAG}")
