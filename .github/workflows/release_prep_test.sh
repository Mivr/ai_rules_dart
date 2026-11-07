#!/usr/bin/env bash
# Tests release_prep.sh against fakes on PATH. Needs no network and runs in seconds.
set -o errexit -o nounset -o pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prep="$here/release_prep.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"

cat >"$work/bin/bazel" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
case "$*" in
  *"query"*)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--output_file" ]; then touch "$a"; fi
      if [[ "$a" =~ ^--output_file=(.*)$ ]]; then touch "${BASH_REMATCH[1]}"; fi
      prev="$a"
    done
    ;;
  *"build"*)
    ;;
  *"info bazel-bin"*)
    mkdir -p "$dir/bazel-bin"
    echo "$dir/bazel-bin"
    ;;
  *"@multitool//tools/git-cliff"*)
    echo "$*" >> "$dir/cliff.calls"
    echo "${@: -1}" >> "$dir/cliff.ranges"
    ;;
  *)
    echo "fake bazel: unexpected call: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/bazel"

cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
echo "$*" >> "$dir/curl.calls"

read_stdin=0
prev=""
for a in "$@"; do
  if [ "$a" = "-K" ] || [ "$a" = "--config" ]; then
    prev="$a"
  elif [ "$prev" = "-K" ] || [ "$prev" = "--config" ]; then
    if [ "$a" = "-" ]; then
      read_stdin=1
    fi
    prev=""
  elif [ "$a" = "-K-" ] || [ "$a" = "--config=-" ]; then
    read_stdin=1
  fi
done

if [ "$read_stdin" -eq 1 ]; then
  cat - >> "$dir/curl.stdin" || true
fi

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
  if [ -f "$dir/releases.page$page.json" ]; then
    cat "$dir/releases.page$page.json" > "$out_file"
  elif [ -f "$dir/releases.json" ]; then
    cat "$dir/releases.json" > "$out_file"
  else
    echo "[]" > "$out_file"
  fi
else
  if [ -f "$dir/releases.page$page.json" ]; then
    cat "$dir/releases.page$page.json"
  elif [ -f "$dir/releases.json" ]; then
    cat "$dir/releases.json"
  else
    echo "[]"
  fi
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

start_case() {
  CASE="$1"
  D="$work/$CASE"
  failed=0
  mkdir -p "$D/repo/tools"
  (
    cd "$D/repo"
    git init -q
    git config user.name "test"
    git config user.email "test@example.com"
    touch cliff.toml tools/cliff.toml
    git add .
    git commit -q -m "initial"
    git tag v0.25.1
    git commit --allow-empty -q -m "middle unreleased"
    git tag v0.26.0
    git commit --allow-empty -q -m "latest release"
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
finish_case

# Case 2: Failed lookup (request fails) exits non-zero with release_prep: message.
start_case lookup_request_fails
touch "$D/curl.fail"
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
finish_case

# Case 3: Failed lookup (unparsable response) exits non-zero with release_prep: message.
start_case lookup_response_unparsable
cat >"$D/releases.json" <<'JSON'
<html>502 Bad Gateway</html>
JSON
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
finish_case

# Case 4: No earlier published release exists; exits non-zero with release_prep: message.
start_case no_earlier_published_release
cat >"$D/releases.json" <<'JSON'
[]
JSON
run_prep v0.26.1
want_exit 1
want_output "release_prep:"
finish_case

# Case 5: Pagination follows until an older published release is found.
start_case pagination_finds_older_release
cat >"$D/releases.page1.json" <<'JSON'
[
  {"tag_name": "v0.27.0", "draft": false},
  {"tag_name": "v0.26.1", "draft": false}
]
JSON
cat >"$D/releases.page2.json" <<'JSON'
[
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 6: Draft releases do not count.
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

# Case 7: Only tags matching v<major>.<minor>.<patch> count.
start_case non_semver_tags_ignored
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.26.0-rc1", "draft": false},
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1
want_exit 0
want_cliff_range "v0.25.1..v0.26.1"
finish_case

# Case 8: Older releases compared numerically, not as strings.
start_case semver_numeric_comparison
(
  cd "$D/repo"
  git tag v0.9.0 v0.25.1
  git tag v0.9.1 v0.26.0
  git tag v0.10.0 v0.26.1
)
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.10.0", "draft": false},
  {"tag_name": "v0.9.1", "draft": false}
]
JSON
run_prep v0.10.0
want_exit 0
want_cliff_range "v0.9.1..v0.10.0"
finish_case

# Case 9: If a token is present, it never appears on command line or in output.
start_case token_not_leaked
secret="ghp_SUPER_SECRET_TOKEN_DO_NOT_LEAK"
cat >"$D/releases.json" <<'JSON'
[
  {"tag_name": "v0.25.1", "draft": false}
]
JSON
run_prep v0.26.1 GH_TOKEN="$secret"
want_exit 0
if grep -qF -- "$secret" "$D/curl.calls"; then
  fail "token was found in curl argv"
fi
if grep -qF -- "$secret" "$D/out"; then
  fail "token was found in output"
fi
if ! grep -qF -- "$secret" "$D/curl.stdin"; then
  fail "token was not delivered to curl config via stdin"
fi
finish_case

# Case 10: Releases on page unordered; newest semver is picked.
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

# Case 11: Missing tag argument exits non-zero with release_prep: message.
start_case missing_tag_fails
run_prep ""
want_exit 1
want_output "release_prep:"
finish_case

# Case 12: Invalid semver tag argument exits non-zero with release_prep: message.
start_case invalid_tag_fails
run_prep "not-a-tag"
want_exit 1
want_output "release_prep:"
finish_case

echo "release_prep_test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
