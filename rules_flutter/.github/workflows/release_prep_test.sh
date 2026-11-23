#!/usr/bin/env bash
# Tests release_prep.sh against fakes for curl and bazel on PATH and a throwaway
# git repository whose middle tag has no published release. Needs no network and
# no Bazel, and runs in seconds. RELEASE_PREP_SCRIPT points the test at another
# copy of the script, to show that the test fails on an older one.
set -o errexit -o nounset -o pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prep="${RELEASE_PREP_SCRIPT:-$here/release_prep.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

token="s3cr3t-test-token"
tag="v1.3.0"

# The fake curl serves, by URL: the ai_rules_dart archive and its release
# metadata (with the archive's real digest), and the ai_rules_flutter release
# list from $FAKE_DIR/releases.json (or the Nth page from releases.pageN.json).
# It fails the releases request when $FAKE_DIR/releases.fail exists, and it
# records every command line in $FAKE_DIR/curl.argv.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
echo "$*" >>"$FAKE_DIR/curl.argv"
out=""
url=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --output ]; then out="$arg"; fi
  prev="$arg"
  url="$arg"
done
# A curl config on stdin (-K -) carries the token; read it like curl would.
if printf '%s ' "$@" | grep -q -- '-K -'; then cat >>"$FAKE_DIR/curl.stdin"; fi
case "$url" in
  *github.com/Mivr/ai_rules_dart/releases/download/*)
    printf 'fake dart archive\n' >"$out"
    ;;
  *api.github.com/repos/Mivr/ai_rules_dart/releases/tags/*)
    digest="sha256:$(sha256sum "$FAKE_DIR/dart.tar.gz.expected" | cut -d' ' -f1)"
    printf '{"assets":[{"name":"%s","digest":"%s"}]}\n' "rules_dart-v2.0.0.tar.gz" "$digest" >"$out"
    ;;
  *api.github.com/repos/Mivr/ai_rules_flutter/releases*)
    if [ -f "$FAKE_DIR/releases.fail" ]; then
      echo "curl: (22) The requested URL returned error: 403" >&2
      exit 22
    fi
    page=$(printf '%s' "$url" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
    if [ -f "$FAKE_DIR/releases.page${page:-1}.json" ]; then
      cp "$FAKE_DIR/releases.page${page:-1}.json" "$out"
    else
      cp "$FAKE_DIR/releases.json" "$out"
    fi
    ;;
  *)
    echo "fake curl: unexpected call: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/curl"

# The fake bazel answers the docs query/build/info calls and records the
# arguments of `bazel run`, the notes step, in $FAKE_DIR/notes.argv.
cat >"$work/bin/bazel" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
args=("$@")
cmd=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    query | build | info | run | shutdown)
      cmd="${args[$i]}"
      break
      ;;
  esac
done
case "$cmd" in
  query)
    for arg in "$@"; do
      case "$arg" in --output_file=*) echo "//docs:doc" >"${arg#--output_file=}" ;; esac
    done
    ;;
  build | shutdown) ;;
  info)
    mkdir -p "$FAKE_DIR/bin_out"
    : >"$FAKE_DIR/bin_out/doc.binaryproto"
    echo "$FAKE_DIR/bin_out"
    ;;
  run)
    printf '%s\n' "$*" >"$FAKE_DIR/notes.argv"
    echo "FAKE-NOTES"
    ;;
  *)
    echo "fake bazel: unexpected call: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/bazel"

# A repository with tags v1.0.0 (published), v1.1.0 (refused, no release),
# v1.2.0 (a draft release) and v1.3.0, the tag being released.
repo="$work/repo"
mkdir -p "$repo"
git_in() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
git_in init --quiet
git_in checkout --quiet -b main
printf 'bazel_dep(name = "ai_rules_dart", version = "2.0.0")\n' >"$repo/MODULE.bazel"
for version in 1.0.0 1.1.0 1.2.0 1.3.0; do
  echo "$version" >"$repo/version.txt"
  git_in add -A
  git_in commit --quiet -m "fix: release $version"
  git_in tag "v$version"
done

# mkrelease <tag> <draft true|false>
mkrelease() {
  jq -nc --arg tag "$1" --argjson draft "$2" '{tag_name: $tag, draft: $draft, prerelease: false}'
}

# releases <release JSON...>: the single page of releases the fake serves.
releases() {
  printf '%s\n' "$@" | jq -s . >"$D/releases.json"
}

# start_case <name>: a fresh fake directory; the dart archive digest is of the
# archive the fake curl writes.
start_case() {
  CASE="$1"
  D="$work/$1"
  failed=0
  mkdir -p "$D"
  printf 'fake dart archive\n' >"$D/dart.tar.gz.expected"
}

fail() {
  echo "FAIL $CASE: $1"
  sed 's/^/    | /' "$D/out"
  failed=1
}

# run_prep: runs release_prep.sh in the repository; sets RC.
run_prep() {
  RC=0
  (cd "$repo" && env PATH="$work/bin:$PATH" FAKE_DIR="$D" GH_TOKEN="$token" bash "$prep" "$tag") >"$D/out" 2>&1 || RC=$?
}

want_exit_zero() {
  [ "$RC" -eq 0 ] || fail "exit $RC, want 0"
}

want_failure() {
  [ "$RC" -ne 0 ] || fail "exit 0, want non-zero"
  grep -q '^release_prep: ' "$D/out" || fail "no release_prep: message"
}

want_message() {
  grep -qF -- "$1" "$D/out" || fail "output lacks: $1"
}

want_no_notes_step() {
  [ ! -f "$D/notes.argv" ] || fail "the notes step ran: $(cat "$D/notes.argv")"
}

# want_range <range>: the notes step got exactly this range, and no --current.
want_range() {
  [ -f "$D/notes.argv" ] || {
    fail "the notes step did not run"
    return
  }
  grep -qF -- " $1" "$D/notes.argv" || fail "notes args lack range $1: $(cat "$D/notes.argv")"
  if grep -q -- '--current' "$D/notes.argv"; then fail "notes args use --current: $(cat "$D/notes.argv")"; fi
}

want_token_hidden() {
  if grep -rqF -- "$token" "$D/out" "$D/curl.argv" 2>/dev/null; then fail "the token leaked"; fi
}

finish_case() {
  want_token_hidden
  if [ "$failed" = 0 ]; then
    echo "ok   $CASE"
    PASS=$((PASS + 1))
  else
    FAILS=$((FAILS + 1))
  fi
}

PASS=0
FAILS=0

start_case notes_start_at_newest_published_release
releases "$(mkrelease v1.0.0 false)" "$(mkrelease v1.2.0 true)"
run_prep
want_exit_zero
want_range "v1.0.0..$tag"
want_message "FAKE-NOTES"
if ! grep -q 'Bearer' "$D/curl.stdin" 2>/dev/null; then fail "the token did not reach curl on stdin"; fi
finish_case

start_case newer_and_foreign_releases_are_ignored
releases "$(mkrelease v1.4.0 false)" "$(mkrelease nightly false)" "$(mkrelease v1.0.0 false)" \
  "$(mkrelease v1.3.0 false)" "$(mkrelease v0.9.0 false)" "$(mkrelease v1.2.0 true)"
run_prep
want_exit_zero
want_range "v1.0.0..$tag"
finish_case

start_case published_middle_tag_is_the_base
releases "$(mkrelease v1.0.0 false)" "$(mkrelease v1.1.0 false)"
run_prep
want_exit_zero
want_range "v1.1.0..$tag"
finish_case

start_case base_found_on_a_later_page
jq -nc '[range(100) | {tag_name: "v9.\(.).0", draft: false}]' >"$D/releases.page1.json"
releases "$(mkrelease v1.0.0 false)"
cp "$D/releases.json" "$D/releases.page2.json"
run_prep
want_exit_zero
want_range "v1.0.0..$tag"
finish_case

start_case request_fails
releases "$(mkrelease v1.0.0 false)"
touch "$D/releases.fail"
run_prep
want_failure
want_message "release_prep: failed to fetch the published releases"
want_no_notes_step
finish_case

start_case response_unparsable
echo 'not json' >"$D/releases.json"
run_prep
want_failure
want_message "release_prep: cannot parse the published releases"
want_no_notes_step
finish_case

start_case response_is_not_a_list
echo '{"message": "API rate limit exceeded"}' >"$D/releases.json"
run_prep
want_failure
want_message "release_prep: the published releases"
want_no_notes_step
finish_case

start_case no_earlier_published_release
releases "$(mkrelease v1.1.0 true)" "$(mkrelease v1.4.0 false)"
run_prep
want_failure
want_message "release_prep: no published release older than $tag"
want_no_notes_step
finish_case

start_case published_tag_missing_from_history
releases "$(mkrelease v0.5.0 false)"
run_prep
want_failure
want_message "release_prep: published release tag v0.5.0 is not in the repository history"
want_no_notes_step
finish_case

echo "release_prep_test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
