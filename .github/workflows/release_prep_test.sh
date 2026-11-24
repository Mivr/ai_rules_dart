#!/usr/bin/env bash
# Tests release_prep.sh against fakes on PATH (bazel, curl) and a real git
# repository of two modules. Needs no network and runs in seconds.
set -o errexit -o nounset -o pipefail
export LC_ALL=C
unset CDPATH

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prep="$here/release_prep.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
real_git="$(command -v git)"

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
  GH_TOKEN GITHUB_TOKEN BAZELISK_GITHUB_TOKEN GITHUB_REPOSITORY RELEASE_OUT

# A fake bazel. It runs in a module directory for the docs, and in
# rules_dart/tools for the release tool and git-cliff. What it was asked is
# recorded in $FAKE_TEST_DIR.
cat >"$work/bin/bazel" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
cmd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output_base=*) echo "$PWD" >>"$dir/docs.dirs"; shift ;;
    -*) shift ;;
    *) cmd="$1"; shift; break ;;
  esac
done
case "$cmd" in
  query)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--output_file" ]; then echo "//docs:x" >"$a"; fi
      case "$a" in --output_file=*) echo "//docs:x" >"${a#--output_file=}" ;; esac
      prev="$a"
    done
    ;;
  build) ;;
  shutdown) ;;
  info)
    mkdir -p "$dir/bazel-bin"
    echo "docs" >"$dir/bazel-bin/docs.binaryproto"
    echo "$dir/bazel-bin"
    ;;
  run)
    target=""
    for a in "$@"; do
      case "$a" in //release:release|@multitool//tools/git-cliff) target="$a"; break ;; esac
    done
    case "$target" in
      //release:release)
        echo "$PWD" >"$dir/tool.dir"
        echo "$*" >>"$dir/tool.calls"
        for a in "$@"; do
          case "$a" in --published=*) cp "${a#--published=}" "$dir/published.seen" ;; esac
        done
        if [ -f "$dir/tool.fail" ]; then echo "release: no base" >&2; exit 1; fi
        cat "$dir/base.ref"
        ;;
      @multitool//tools/git-cliff)
        echo "$PWD" >"$dir/cliff.dir"
        echo "$*" >>"$dir/cliff.calls"
        echo "- a changelog entry"
        ;;
      *) echo "fake bazel: unexpected run: $*" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "fake bazel: unexpected command '$cmd': $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/bazel"

# A fake curl: the GitHub releases API pages, one release's metadata, and the
# release asset of rules_dart.
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_TEST_DIR"
out=""
url=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--output" ]; then out="$a"; fi
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
echo "$*" >>"$dir/curl.calls"
if [ -f "$dir/curl.fail" ]; then
  echo "curl: (22) The requested URL returned error: 500" >&2
  exit 22
fi
src=""
case "$url" in
  *"/releases?per_page="*)
    page="${url##*page=}"
    if [ -f "$dir/releases.page$page.json" ]; then src="$dir/releases.page$page.json"
    elif [ -f "$dir/releases.json" ]; then src="$dir/releases.json"
    else echo "[]" >"$out"; exit 0; fi
    ;;
  */releases/tags/*) src="$dir/dart_release.json" ;;
  */releases/download/*) src="$dir/dart_asset" ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 2 ;;
esac
[ -f "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$src" >"$out"
FAKE
chmod +x "$work/bin/curl"

# git, except that `fetch` can be made to fail.
cat >"$work/bin/git" <<FAKE
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="\${FAKE_TEST_DIR:-}"
if [ -n "\$dir" ]; then
  echo "\$*" >>"\$dir/git.calls"
  if [ -f "\$dir/git.fetch.fail" ]; then
    for arg in "\$@"; do
      if [ "\$arg" = "fetch" ]; then
        echo "fatal: fake git fetch failure" >&2
        exit 128
      fi
    done
  fi
fi
exec "$real_git" "\$@"
FAKE
chmod +x "$work/bin/git"

sha256_of() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
integrity_of() { echo "sha256-$(openssl dgst -sha256 -binary "$1" | openssl base64 -A)"; }

# A repository of two modules, as the real one is: each module has its own
# .gitattributes, and the root has neither MODULE.bazel nor BUILD.bazel.
init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    "$real_git" init -q
    "$real_git" config user.name test
    "$real_git" config user.email test@example.com
    "$real_git" config commit.gpgsign false
    "$real_git" config tag.gpgSign false
    mkdir -p rules_dart/dart rules_dart/e2e/smoke rules_dart/e2e/other rules_dart/dev \
      rules_dart/tools rules_flutter/flutter rules_flutter/e2e/smoke rules_flutter/e2e/other
    echo 'module(name = "ai_rules_dart")' >rules_dart/MODULE.bazel
    echo 'x = 1' >rules_dart/dart/defs.bzl
    # shellcheck disable=SC2016 # the placeholder git expands in the archive
    echo '_STAMP = "$Format:%H$"' >rules_dart/BUILD.bazel
    echo 'smoke' >rules_dart/e2e/smoke/MODULE.bazel
    echo 'other' >rules_dart/e2e/other/MODULE.bazel
    echo 'dev' >rules_dart/dev/f.dart
    echo 'tools' >rules_dart/tools/MODULE.bazel
    printf '/e2e/* export-ignore\n/e2e/smoke -export-ignore\n/dev/ export-ignore\n/BUILD.bazel export-subst\n' >rules_dart/.gitattributes
    : >rules_dart/cliff.toml
    printf 'module(name = "ai_rules_flutter")\nbazel_dep(name = "bazel_skylib", version = "1.9.2")\nbazel_dep(name = "ai_rules_dart", version = "0.28.9", repo_name = "rules_dart")\n' >rules_flutter/MODULE.bazel
    echo 'y = 1' >rules_flutter/flutter/defs.bzl
    echo 'smoke' >rules_flutter/e2e/smoke/MODULE.bazel
    echo 'other' >rules_flutter/e2e/other/MODULE.bazel
    printf '/e2e/* export-ignore\n/e2e/smoke -export-ignore\n' >rules_flutter/.gitattributes
    : >rules_flutter/cliff.toml
    "$real_git" add .
    "$real_git" commit --no-verify -q -m initial
    "$real_git" tag rules_dart-v0.28.9
    "$real_git" tag rules_flutter-v0.30.2
    "$real_git" commit --no-verify --allow-empty -q -m next
    "$real_git" tag -a rules_dart-v0.29.0 -m rules_dart
    "$real_git" tag -a rules_flutter-v0.30.3 -m rules_flutter
    "$real_git" remote add origin .
  )
}

start_case() {
  CASE="$1"
  D="$work/$CASE"
  failed=0
  init_repo "$D/repo"
  echo "rules_dart-v0.28.9" >"$D/base.ref"
  mkdir -p "$D/out"
}

fail() {
  echo "FAIL $CASE: $1"
  if [ -f "$D/stdout" ]; then sed 's/^/    | /' "$D/stdout"; fi
  if [ -f "$D/stderr" ]; then sed 's/^/    ! /' "$D/stderr"; fi
  failed=1
}

# run_prep <tag> [VAR=value ...]: stdout in $D/stdout, stderr in $D/stderr.
run_prep() {
  local tag="$1"
  shift || true
  RC=0
  (
    cd "$D/repo"
    env PATH="$work/bin:$PATH" FAKE_TEST_DIR="$D" RELEASE_OUT="$D/out" \
      "$@" bash "$prep" ${tag:+"$tag"} >"$D/stdout" 2>"$D/stderr"
  ) || RC=$?
}

want_exit() { [ "$RC" -eq "$1" ] || fail "exit $RC, want $1"; }
want_stderr() { grep -qF -- "$1" "$D/stderr" || fail "stderr lacks: $1"; }
want_stdout() { grep -qF -- "$1" "$D/stdout" || fail "stdout lacks: $1"; }
want_no_cliff() { [ ! -f "$D/cliff.calls" ] || fail "git-cliff was called: $(cat "$D/cliff.calls")"; }
want_no_archive() { [ -z "$(ls -A "$D/out")" ] && return 0; [ "$1" = keep ] || fail "files were written: $(ls "$D/out")"; }

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

# Case 1: rules_dart's archive holds the module only, under the prefix the BCR
# template names, with MODULE.bazel at its top and what export-ignore removes
# left out; the snippet and the notes name the module's own files and range.
start_case dart_archive_is_the_module_only
echo '[{"tag_name": "rules_dart-v0.28.9", "draft": false}]' >"$D/releases.json"
run_prep rules_dart-v0.29.0 GITHUB_REPOSITORY=Mivr/ai_rules_dart
want_exit 0
archive="$D/out/rules_dart-v0.29.0.tar.gz"
if [ -f "$archive" ]; then
  tar tzf "$archive" >"$D/list"
  grep -qx 'rules_dart-0.29.0/MODULE.bazel' "$D/list" || fail "MODULE.bazel is not at the top of the prefix"
  grep -qx 'rules_dart-0.29.0/e2e/smoke/MODULE.bazel' "$D/list" || fail "e2e/smoke is not in the archive"
  grep -q 'e2e/other\|/dev/\|rules_flutter' "$D/list" && fail "the archive holds what export-ignore removes, or the other module"
  grep -qv '^rules_dart-0.29.0/' "$D/list" && fail "an entry is outside the prefix"
  tar xzOf "$archive" rules_dart-0.29.0/BUILD.bazel | grep -qx "_STAMP = \"$(git -C "$D/repo" rev-parse "rules_dart-v0.29.0^{commit}")\"" ||
    fail "export-subst did not stamp BUILD.bazel with the commit"
  want_stdout "urls = [\"https://github.com/Mivr/ai_rules_dart/releases/download/rules_dart-v0.29.0/rules_dart-v0.29.0.tar.gz\"]"
  want_stdout "integrity = \"$(integrity_of "$archive")\""
  want_stdout 'strip_prefix = "rules_dart-0.29.0"'
else
  fail "no archive $archive"
fi
[ -s "$D/out/rules_dart-v0.29.0.docs.tar.gz" ] || fail "no docs archive"
[ "$(sort -u "$D/docs.dirs")" = "$D/repo/rules_dart" ] || fail "the docs were built in $(sort -u "$D/docs.dirs"), not in rules_dart/"
grep -qF -- "--module=rules_dart --tag=rules_dart-v0.29.0" "$D/tool.calls" || fail "release tool call: $(cat "$D/tool.calls")"
[ "$(cat "$D/tool.dir")" = "$D/repo/rules_dart/tools" ] || fail "the tool ran in $(cat "$D/tool.dir")"
grep -qF -- "--config $D/repo/rules_dart/cliff.toml --strip header rules_dart-v0.28.9..rules_dart-v0.29.0" "$D/cliff.calls" ||
  fail "git-cliff call: $(cat "$D/cliff.calls")"
grep -qF -- "--workdir $D/repo" "$D/cliff.calls" || fail "git-cliff does not work in the repository root"
want_stdout "- a changelog entry"
finish_case

# Case 2: the same tag gives the same bytes (no file names or times in the
# gzip header), so the same sha256.
start_case archive_is_reproducible
echo '[]' >"$D/releases.json"
run_prep rules_dart-v0.29.0
first="$(sha256_of "$D/out/rules_dart-v0.29.0.tar.gz")"
sleep 1
rm -f "$D/out"/*
run_prep rules_dart-v0.29.0
[ "$first" = "$(sha256_of "$D/out/rules_dart-v0.29.0.tar.gz")" ] || fail "two runs made different archives"
finish_case

# Case 3: the tool is told which tags have a published release: drafts are
# left out, every page is read, and the tags of both modules are passed (the
# tool picks the module's own).
start_case published_releases_reach_the_tool
cat >"$D/releases.page1.json" <<'JSON'
[
  {"tag_name": "rules_dart-v0.28.9", "draft": false},
  {"tag_name": "rules_dart-v0.28.8", "draft": true}
]
JSON
cat >"$D/releases.page2.json" <<'JSON'
[
  {"tag_name": "rules_flutter-v0.30.2", "draft": false},
  {"tag_name": "v0.28.3", "draft": false}
]
JSON
cat >"$D/releases.page3.json" <<'JSON'
[
  {"tag_name": "v0.27.0", "draft": false}
]
JSON
run_prep rules_dart-v0.29.0 RELEASE_PREP_PER_PAGE=2
want_exit 0
[ "$(sort "$D/published.seen" | tr '\n' ' ')" = "rules_dart-v0.28.9 rules_flutter-v0.30.2 v0.27.0 v0.28.3 " ] ||
  fail "the tool was given: $(tr '\n' ' ' <"$D/published.seen")"
grep -qF -- "https://api.github.com/repos/Mivr/ai_rules_dart/releases?per_page=2&page=3" "$D/curl.calls" || fail "page 3 was not read"
finish_case

# Case 4: rules_flutter's archive holds its module only, and its snippet names
# the rules_dart release its floor names, with the integrity of that release's
# archive, verified against the digest GitHub recorded.
start_case flutter_archive_and_the_dart_floor
echo '[]' >"$D/releases.json"
echo "rules_flutter-v0.30.2" >"$D/base.ref"
printf 'the rules_dart 0.28.9 archive\n' >"$D/dart_asset"
printf '{"assets": [{"name": "rules_dart-v0.28.9.tar.gz", "digest": "sha256:%s"}]}\n' "$(sha256_of "$D/dart_asset")" >"$D/dart_release.json"
run_prep rules_flutter-v0.30.3
want_exit 0
archive="$D/out/rules_flutter-v0.30.3.tar.gz"
if [ -f "$archive" ]; then
  tar tzf "$archive" >"$D/list"
  grep -qx 'rules_flutter-0.30.3/MODULE.bazel' "$D/list" || fail "MODULE.bazel is not at the top of the prefix"
  grep -q 'rules_dart\|e2e/other' "$D/list" && fail "the archive holds the other module or an e2e workspace"
fi
want_stdout 'bazel_dep(name = "ai_rules_dart", version = "0.28.9", repo_name = "rules_dart")'
want_stdout 'urls = ["https://github.com/Mivr/ai_rules_dart/releases/download/rules_dart-v0.28.9/rules_dart-v0.28.9.tar.gz"]'
want_stdout "integrity = \"$(integrity_of "$D/dart_asset")\""
want_stdout 'strip_prefix = "rules_dart-0.28.9"'
want_stdout 'strip_prefix = "rules_flutter-0.30.3"'
grep -qF -- "rules_flutter/cliff.toml --strip header rules_flutter-v0.30.2..rules_flutter-v0.30.3" "$D/cliff.calls" || fail "git-cliff call: $(cat "$D/cliff.calls")"
finish_case

# Case 5: a digest that differs from the downloaded archive stops the release.
start_case flutter_dart_digest_mismatch
echo '[]' >"$D/releases.json"
printf 'the rules_dart 0.28.9 archive\n' >"$D/dart_asset"
printf '{"assets": [{"name": "rules_dart-v0.28.9.tar.gz", "digest": "sha256:00"}]}\n' >"$D/dart_release.json"
run_prep rules_flutter-v0.30.3
want_exit 1
want_stderr "release_prep: rules_dart-v0.28.9.tar.gz sha256"
want_no_cliff
finish_case

# Case 6: a floor that is not released (no archive to download) stops it.
start_case flutter_floor_not_released
echo '[]' >"$D/releases.json"
run_prep rules_flutter-v0.30.3
want_exit 1
want_stderr "release rules_dart 0.28.9 first"
want_no_cliff
finish_case

# Case 7: the tag decides the module; anything else is refused before any file
# is written.
for bad in "" v0.29.0 rules_dart-0.29.0 rules_dart-v0.29 rules_dart-v0.29.0-rc1 rules_other-v1.0.0 rules_dart-v0.29.0.1; do
  start_case "refuses_tag_${bad:-empty}"
  run_prep "$bad"
  want_exit 1
  want_stderr "release_prep:"
  want_no_cliff
  [ -z "$(ls -A "$D/out")" ] || fail "files were written: $(ls "$D/out")"
  finish_case
done

# Case 8: a tag whose commit has no module directory is refused.
start_case tag_without_the_module
(cd "$D/repo" && "$real_git" rm -rq rules_dart && "$real_git" commit --no-verify -q -m gone && "$real_git" tag rules_dart-v0.30.0)
run_prep rules_dart-v0.30.0
want_exit 1
want_stderr "has no rules_dart/ directory"
finish_case

# Case 9: a failed request, an unparsable answer and a rate-limit object each
# stop the release, with a release_prep: message and no git-cliff.
start_case releases_request_fails
touch "$D/curl.fail"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "release_prep: request to GitHub releases API failed"
want_no_cliff
finish_case

start_case releases_response_unparsable
echo '<html>502 Bad Gateway</html>' >"$D/releases.json"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "release_prep: could not parse GitHub releases response"
want_no_cliff
finish_case

start_case releases_response_not_a_list
echo '{"message": "API rate limit exceeded"}' >"$D/releases.json"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "release_prep: could not parse GitHub releases response"
want_no_cliff
finish_case

# Case 10: a failed fetch stops it and keeps git's own message.
start_case fetch_fails_stops_prep
echo '[]' >"$D/releases.json"
touch "$D/git.fetch.fail"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "release_prep: git fetch --tags failed"
want_stderr "fatal: fake git fetch failure"
want_no_cliff
finish_case

# Case 11: the tool finds no base, or one that is not in the history: no
# notes, no fallback to the whole history.
start_case tool_finds_no_base
echo '[]' >"$D/releases.json"
touch "$D/tool.fail"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "release_prep: cannot find where the notes of rules_dart-v0.29.0 start"
want_no_cliff
finish_case

start_case base_not_in_history
echo '[]' >"$D/releases.json"
echo "rules_dart-v0.1.0" >"$D/base.ref"
run_prep rules_dart-v0.29.0
want_exit 1
want_stderr "which is not in the repository history"
want_no_cliff
finish_case

# Case 12: a complete repository fetches without --unshallow; a shallow one with.
start_case complete_repo_no_unshallow
echo '[]' >"$D/releases.json"
run_prep rules_dart-v0.29.0
want_exit 0
grep -qF -- "--unshallow" "$D/git.calls" && fail "fetch passed --unshallow on a complete repository"
grep -qF -- "fetch --tags origin" "$D/git.calls" || fail "no fetch --tags: $(cat "$D/git.calls")"
finish_case

# Case 13: ambient tokens never appear on a command line or in the output,
# even under -x.
start_case token_not_leaked
echo '[]' >"$D/releases.json"
secret_gh="ghp_SUPER_SECRET_GH_TOKEN_DO_NOT_LEAK"
secret_hub="ghs_SUPER_SECRET_GITHUB_TOKEN_DO_NOT_LEAK"
RC=0
(
  cd "$D/repo"
  env PATH="$work/bin:$PATH" FAKE_TEST_DIR="$D" RELEASE_OUT="$D/out" \
    GH_TOKEN="$secret_gh" GITHUB_TOKEN="$secret_hub" \
    bash -x "$prep" rules_dart-v0.29.0 >"$D/stdout" 2>"$D/stderr"
) || RC=$?
want_exit 0
for tok in "$secret_gh" "$secret_hub"; do
  grep -qF -- "$tok" "$D/curl.calls" 2>/dev/null && fail "token appeared in a curl command line"
  grep -qF -- "$tok" "$D/stdout" "$D/stderr" && fail "token appeared in the output"
done
finish_case

echo "release_prep_test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
