#!/usr/bin/env bash
# Tests release_prep.sh against fakes on PATH. Needs no network and runs in seconds.
set -o errexit -o nounset -o pipefail
export LC_ALL=C
unset CDPATH

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prep="$here/release_prep.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Isolate git, temp files and ambient credentials from the host environment so
# global hooks (core.hooksPath), GPG signing or caller tokens never affect runs.
export HOME="$work/home"
export XDG_CONFIG_HOME="$work/home/.config"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export TMPDIR="$work/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMPDIR" "$work/bin"
: >"$GIT_CONFIG_GLOBAL"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CEILING_DIRECTORIES \
  GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
  GH_TOKEN GITHUB_TOKEN BAZELISK_GITHUB_TOKEN REPO

cat >"$work/bin/bazel" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
cmd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --*=*) shift ;;
    --output_base|--output_user_root) shift 2 ;;
    -*) shift ;;
    *) cmd="$1"; shift; break ;;
  esac
done
case "$cmd" in
  query)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--output_file" ]; then : >"$a"; fi
      case "$a" in
        --output_file=*) : >"${a#--output_file=}" ;;
      esac
      prev="$a"
    done
    ;;
  build)
    ;;
  info)
    if [ "${1:-}" = "bazel-bin" ]; then
      mkdir -p "$dir/bazel-bin"
      echo "$dir/bazel-bin"
    else
      echo "fake bazel: unexpected info key: $*" >&2
      exit 2
    fi
    ;;
  run)
    if [ "${1:-}" = "@multitool//tools/git-cliff" ]; then
      echo "run $*" >>"$dir/cliff.calls"
      last=""
      for a in "$@"; do last="$a"; done
      echo "$last" >>"$dir/cliff.ranges"
    else
      echo "fake bazel: unexpected run target: $*" >&2
      exit 2
    fi
    ;;
  *)
    echo "fake bazel: unexpected command '$cmd': $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/bazel"

cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
echo "$*" >>"$dir/curl.calls"

if [ -f "$dir/curl.fail" ]; then
  echo "curl: (22) The requested URL returned error: 500" >&2
  exit 22
fi

page=1
page_re="[?&]page=([0-9]+)"
for arg in "$@"; do
  if [[ "$arg" =~ $page_re ]]; then
    page="${BASH_REMATCH[1]}"
  fi
done

if [ -f "$dir/curl.fail.page$page" ]; then
  echo "curl: (22) The requested URL returned error: 500" >&2
  exit 22
fi

body_file=""
if [ -f "$dir/releases.page$page.json" ]; then
  body_file="$dir/releases.page$page.json"
elif [ -f "$dir/releases.json" ]; then
  body_file="$dir/releases.json"
fi

out_file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then
    out_file="$a"
    prev=""
  elif [ "$a" = "-o" ] || [ "$a" = "--output" ]; then
    prev="$a"
  elif [[ "$a" =~ ^--output=(.*)$ ]]; then
    out_file="${BASH_REMATCH[1]}"
  fi
done

if [ -n "$out_file" ]; then
  if [ -n "$body_file" ]; then cat "$body_file" >"$out_file"; else echo "[]" >"$out_file"; fi
else
  if [ -n "$body_file" ]; then cat "$body_file"; else echo "[]"; fi
fi
FAKE
chmod +x "$work/bin/curl"

cat >"$work/bin/shasum" <<'FAKE'
#!/usr/bin/env bash
echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  -"
FAKE
chmod +x "$work/bin/shasum"

cat >"$work/bin/openssl" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "base64" ]; then
  cat >/dev/null 2>&1 || true
  echo "dummyintegrityhash=="
else
  echo "dummybinarydgst"
fi
FAKE
chmod +x "$work/bin/openssl"

init_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/tools"
  (
    cd "$repo_dir"
    git init -q
    git config user.name "test"
    git config user.email "test@example.com"
    git config commit.gpgsign false
    git config tag.gpgSign false
    touch cliff.toml tools/cliff.toml
    git add .
    git commit --no-verify -q -m "initial"
  )
}

start_case() {
  CASE="$1"
  D="$work/$CASE"
  failed=0
  init_repo "$D/repo"
  (
    cd "$D/repo"
    git tag v0.25.1
    git commit --no-verify --allow-empty -q -m "middle unreleased"
    git tag v0.26.0
    git commit --no-verify --allow-empty -q -m "latest release"
    git tag v0.26.1
    git remote add origin .
  )
}

fail() {
  echo "FAIL $CASE: $1"
  if [ -f "$D/out" ]; then
    sed 's/^/    | /' "$D/out"
  fi
  failed=1
}

run_prep() {
  local tag="${1-v0.26.1}"
  shift || true
  RC=0
  (
    cd "$D/repo"
    env PATH="$work/bin:$PATH" FAKE_TEST_DIR="$D" GITHUB_WORKSPACE="$D/repo" \
      "$@" bash "$prep" ${tag:+"$tag"} >"$D/out" 2>&1
  ) || RC=$?
}

want_exit() {
  [ "$RC" -eq "$1" ] || fail "exit $RC, want $1"
}

want_output() {
  grep -qF -- "$1" "$D/out" || fail "output lacks: $1"
}

want_cliff_range() {
  local want="$1"
  if [ ! -f "$D/cliff.ranges" ]; then
    fail "git-cliff was never called"
    return
  fi
  local got
  got="$(tail -n 1 "$D/cliff.ranges")"
  [ "$got" = "$want" ] || fail "git-cliff range was '$got', want '$want'"
}

want_no_cliff() {
  if [ -f "$D/cliff.ranges" ]; then
    fail "git-cliff was unexpectedly called with: $(cat "$D/cliff.ranges")"
  fi
}

finish_case() {
  if [ "$failed" = 0 ]; then
    echo "ok   $CASE"
    PASS=$((PASS + 1))
  else
    FAILS=$((FAILS + 1))
  fi
}

PASS=0
FAILS=0

# Case 1: Middle tag has no published release; notes start at newest published release.
start_case middle_tag_unreleased_skipped
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
grep -qF "https://api.github.com/repos/Mivr/ai_rules_dart/releases" "$D/curl.calls" 2>/dev/null \
  || fail "did not query Mivr/ai_rules_dart releases endpoint"
finish_case

# Case 2: Failed lookup (request fails) exits non-zero with release_prep: message.
start_case lookup_request_fails
touch "$D/curl.fail"
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 3: Failed lookup (unparsable response) exits non-zero with release_prep: message.
start_case lookup_response_unparsable
cat >"$D/releases.json" <<'JSON'
<html>502 Bad Gateway</html>
JSON
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 4: Failed lookup (non-array JSON error object) exits non-zero with release_prep: message.
start_case lookup_response_not_a_list
cat >"$D/releases.json" <<'JSON'
{"message": "API rate limit exceeded"}
JSON
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 5: No earlier published release exists; exits non-zero with release_prep: message.
start_case no_earlier_published_release
cat >"$D/releases.json" <<'JSON'
[]
JSON
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 6: First tag in repo has no earlier git tag or release; never falls back to all history.
CASE="first_tag_no_unbounded_fallback"
D="$work/$CASE"
failed=0
init_repo "$D/repo"
(
  cd "$D/repo"
  git tag v0.1.0
  git remote add origin .
)
cat >"$D/releases.json" <<'JSON'
[]
JSON
run_prep v0.1.0
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 7: Pagination follows until an older published release is found.
start_case pagination_finds_older_release
cat >"$D/releases.page1.json" <<'JSON'
[
  {"tag_name": "v0.27.0", "draft": false},
  {"tag_name": "v0.26.1", "draft": false}
]
JSON
cat >"$D/releases.page2.json" <<'JSON'
[
  {"tag_name": "v0.26.0", "draft": true}
]
JSON
cat >"$D/releases.page3.json" <<'JSON'
[
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 8: Draft releases do not count.
start_case draft_releases_ignored
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.26.0", "draft": true},
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 9: Only tags matching v<major>.<minor>.<patch> count.
start_case non_semver_tags_ignored
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.26.0-rc1", "draft": false},
  {"tag_name": "release-2026", "draft": false},
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 10: Older releases compared numerically, not as strings.
CASE="semver_numeric_comparison"
D="$work/$CASE"
failed=0
init_repo "$D/repo"
(
  cd "$D/repo"
  git tag v0.9.1
  git commit --no-verify --allow-empty -q -m "unreleased middle"
  git tag v0.9.2
  git commit --no-verify --allow-empty -q -m "ten"
  git tag v0.10.0
  git remote add origin .
)
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.10.0", "draft": false},
  {"tag_name": "v0.9.1", "draft": false},
  {"tag_name": "v0.2.0", "draft": false}
]
JSON
run_prep v0.10.0
want_exit 0
want_cliff_range "v0.9.1..v0.10.0"
finish_case

# Case 11: Releases on page unordered; newest semver older than target is picked.
start_case newest_semver_picked_when_unordered
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.24.0", "draft": false},
  {"tag_name": "v0.25.1", "draft": false},
  {"tag_name": "v0.25.0", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 12: Ambient tokens never appear on command line or in output (even under -x).
start_case token_not_leaked
secret_gh="ghp_SUPER_SECRET_GH_TOKEN_DO_NOT_LEAK"
secret_hub="ghs_SUPER_SECRET_GITHUB_TOKEN_DO_NOT_LEAK"
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
RC=0
(
  cd "$D/repo"
  env PATH="$work/bin:$PATH" FAKE_TEST_DIR="$D" GITHUB_WORKSPACE="$D/repo" \
    GH_TOKEN="$secret_gh" GITHUB_TOKEN="$secret_hub" \
    bash -x "$prep" v0.26.1 >"$D/out" 2>&1
) || RC=$?
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
[ -f "$D/curl.calls" ] || fail "curl was never called"
for tok in "$secret_gh" "$secret_hub"; do
  if grep -qF -- "$tok" "$D/curl.calls" 2>/dev/null; then
    fail "token appeared in curl command line"
  fi
  if grep -qF -- "$tok" "$D/out"; then
    fail "token appeared in script output"
  fi
done
finish_case

# Case 13: Missing tag argument exits non-zero with release_prep: message.
start_case missing_tag_fails
run_prep ""
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

# Case 14: Invalid semver tag argument exits non-zero with release_prep: message.
start_case invalid_tag_fails
run_prep "not-a-tag"
want_exit 1
want_output "release_prep:"
want_no_cliff
finish_case

echo "release_prep_test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
