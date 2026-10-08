#!/usr/bin/env bash
# Regression tests for the pinned-base publish guard and task branch creation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-publish-guard)
FAKEBIN="$TMP_ROOT/fakebin"
REAL_GIT=$(command -v git)
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-} ${2:-}" in
  "pr list")
    if [ -n "${FM_TEST_PR_LIST:-}" ]; then
      cat "$FM_TEST_PR_LIST"
    fi
    ;;
  "pr view")
    printf 'base: %s\nhead: %s\n' "${FM_TEST_PR_BASE:-main}" "${FM_TEST_PR_HEAD:-fm/task}"
    ;;
  *)
    echo "unexpected gh-axi request: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
fetch=0
for arg in "${args[@]}"; do
  [ "$arg" = fetch ] && fetch=1
done
if [ "$fetch" = 1 ] && [ -n "${FM_TEST_GIT_FETCH_URL:-}" ]; then
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = https://github.com/Ivory2024/firstmate.git ]; then
      args[$i]="file://$FM_TEST_GIT_FETCH_URL"
    fi
  done
fi
exec "$FM_TEST_REAL_GIT" "${args[@]}"
SH
chmod +x "$FAKEBIN/git"

new_case() { # <name> [source-base-ref]
  local name=$1 source_ref=${2:-refs/heads/main}
  TEST_REPO="$TMP_ROOT/$name"
  mkdir -p "$TEST_REPO"
  git init --quiet -b main "$TEST_REPO"
  git -C "$TEST_REPO" config user.name 'Firstmate Tests'
  git -C "$TEST_REPO" config user.email 'tests@example.invalid'
  printf 'base\n' > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit --quiet -m base
  git -C "$TEST_REPO" config firstmate.baseMode local
  git -C "$TEST_REPO" config firstmate.expectedRepository Ivory2024/firstmate
  git -C "$TEST_REPO" config firstmate.baseRef "$source_ref"
  if [ "$source_ref" != refs/heads/main ]; then
    git -C "$TEST_REPO" update-ref "$source_ref" HEAD
  fi
  git -C "$TEST_REPO" checkout --quiet --detach refs/heads/main
  (
    # shellcheck source=bin/fm-git-base-lib.sh
    . "$ROOT/bin/fm-git-base-lib.sh"
    fm_git_base_refresh_worktree "$TEST_REPO" "$TEST_REPO"
  ) || fail "could not pin the fixture's explicit local base"
  (
    cd "$TEST_REPO"
    "$ROOT/bin/fm-publish-guard.sh" branch fm/task
  ) >/dev/null || fail "could not create the fixture task branch from its verified base"
  TEST_BASE=$(git -C "$TEST_REPO" rev-parse refs/heads/main)
  TEST_SCOPE="$(git -C "$TEST_REPO" rev-parse --absolute-git-dir)/info/fm-publish-scope"
  TEST_PR_LIST="$TMP_ROOT/$name.pr-list"
  printf 'count: 0 (showing first 0)\npull_requests: []\n' > "$TEST_PR_LIST"
  export FM_TEST_PR_LIST="$TEST_PR_LIST" FM_TEST_PR_BASE=main FM_TEST_PR_HEAD=fm/task
}

write_scope() { # <pattern> <per-path-bytes> <total-bytes>
  local pattern=$1 path_limit=$2 total_limit=$3
  mkdir -p "$(dirname "$TEST_SCOPE")"
  printf '%s\t%s\n@total\t%s\n' "$pattern" "$path_limit" "$total_limit" > "$TEST_SCOPE"
}

commit_all() { # <message>
  git -C "$TEST_REPO" add -A
  git -C "$TEST_REPO" commit --quiet -m "$1"
}

run_guard() {
  (cd "$TEST_REPO" && FM_TEST_REAL_GIT="$REAL_GIT" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-publish-guard.sh" check 2>&1)
}

test_correct_base_scoped_delta_passes() {
  local out status
  new_case scoped-delta
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'expected task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  out=$(run_guard); status=$?
  expect_code 0 "$status" "a scoped task delta from the pinned base should pass"$'\n'"$out"
  assert_contains "$out" "PUBLISH_GUARD: PASS: base=$TEST_BASE" "guard did not report the pinned base"
  assert_contains "$out" 'unexpected=0' "guard did not report zero unexpected commits"
  pass "correct base with scoped delta passes the publish guard"
}

test_linked_worktrees_keep_private_base_pins() {
  local other pin_one pin_two
  new_case linked-pin-isolation
  other="$TMP_ROOT/linked-pin-isolation-other"
  git -C "$TEST_REPO" worktree add --quiet --detach "$other" refs/heads/main
  (
    # shellcheck source=bin/fm-git-base-lib.sh
    . "$ROOT/bin/fm-git-base-lib.sh"
    fm_git_base_refresh_worktree "$other" "$other"
  ) || fail "could not create a verified pin in the second worktree"
  pin_one=$(git -C "$TEST_REPO" rev-parse --absolute-git-dir)/info/fm-verified-base
  pin_two=$(git -C "$other" rev-parse --absolute-git-dir)/info/fm-verified-base
  [ "$pin_one" != "$pin_two" ] || fail "linked worktrees share a verified-base pin path"
  assert_contains "$(cat "$pin_one")" 'branch=fm/task' "task worktree pin lost its branch binding"
  assert_not_contains "$(cat "$pin_two")" 'branch=fm/task' \
    "refreshing a second worktree overwrote the task worktree's private pin"
  pass "linked worktrees keep independent verified-base pins"
}

test_hundreds_of_inherited_paths_are_rejected_by_scope() {
  local out status i
  new_case inherited-plugin-migration
  write_scope 'recovery/*.txt' 1000 1000000
  git -C "$TEST_REPO" checkout --quiet -b inherited-plugin-migration "$TEST_BASE"
  mkdir -p "$TEST_REPO/plugin-migration/inherited"
  i=1
  while [ "$i" -le 120 ]; do
    printf 'upstream migration payload %s\n' "$i" > "$TEST_REPO/plugin-migration/inherited/change-$i.txt"
    i=$((i + 1))
  done
  commit_all inherited-plugin-migration-diff
  git -C "$TEST_REPO" checkout --quiet fm/task
  git -C "$TEST_REPO" merge --quiet --ff-only inherited-plugin-migration
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a 120-path plugin-migration-shaped diff passed the task scope allowlist"
  assert_contains "$out" "scope allowlist invariant failed: changed path 'plugin-migration/inherited/change-1.txt'" \
    "large inherited diff refusal did not identify the first unexpected path"
  pass "a 120-path inherited plugin-migration-shaped diff is refused by task scope"
}

test_oversized_scoped_file_is_rejected() {
  local out status
  new_case oversized-file
  write_scope 'recovery/*.txt' 40 5000
  mkdir -p "$TEST_REPO/recovery"
  printf '%0100d\n' 123 > "$TEST_REPO/recovery/oversized.txt"
  commit_all oversized-file
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "an over-budget scoped diff passed the size guard"
  assert_contains "$out" "oversized diff invariant failed: path='recovery/oversized.txt'" \
    "size refusal did not identify the oversized path"
  pass "the byte-budget guard rejects an oversized scoped file"
}

test_pathspec_magic_filename_obeys_byte_budget() {
  local out status path
  new_case literal-pathspec
  path=':(exclude)recovery/secret.txt'
  write_scope "$path" 40 5000
  mkdir -p "$TEST_REPO/$(dirname "$path")"
  printf '%0100d\n' 123 > "$TEST_REPO/$path"
  commit_all literal-pathspec
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a pathspec-magic filename bypassed its byte budget"
  assert_contains "$out" "oversized diff invariant failed: path='$path'" \
    "literal filename budget refusal did not identify the exact path"
  pass "pathspec-magic filename is measured literally"
}

test_unexpected_merged_commits_are_rejected() {
  local out status
  new_case unexpected-commits
  write_scope 'recovery/*.txt' 1000 10000
  git -C "$TEST_REPO" checkout --quiet -b inherited-side "$TEST_BASE"
  mkdir -p "$TEST_REPO/recovery"
  printf 'side commit\n' > "$TEST_REPO/recovery/side.txt"
  commit_all inherited-side-change
  git -C "$TEST_REPO" checkout --quiet fm/task
  mkdir -p "$TEST_REPO/recovery"
  printf 'task commit\n' > "$TEST_REPO/recovery/task.txt"
  commit_all expected-task-change
  git -C "$TEST_REPO" merge --quiet --no-ff inherited-side -m merge-inherited-side
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a task branch containing a side-parent commit passed the ancestry guard"
  assert_contains "$out" 'unexpected inherited commits invariant failed: total=3 first_parent=2 unexpected=1' \
    "guard did not report the unexpected side-parent commit count"
  pass "a side-parent inherited commit is rejected with observed commit counts"
}

test_fast_forwarded_base_commits_are_rejected() {
  local out status
  new_case fast-forwarded-base refs/heads/fm-test-source-base
  write_scope 'recovery/*.txt' 1000 10000
  mkdir -p "$TEST_REPO/recovery"
  printf 'upstream change\n' > "$TEST_REPO/recovery/upstream.txt"
  commit_all upstream-change
  git -C "$TEST_REPO" update-ref refs/heads/fm-test-source-base HEAD
  git -C "$TEST_REPO" branch -D main >/dev/null
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a task branch fast-forwarded to newer base passed the ownership guard"
  assert_contains "$out" 'inherited=1 verified_current_base=' \
    "fast-forward refusal did not identify commits inherited from the verified source base"
  pass "a fast-forwarded newer source base is rejected without local main"
}

test_remote_fast_forward_rejected_without_local_main() {
  local out status fork_remote_dir publisher current_ref
  new_case remote-fast-forward
  write_scope 'recovery/*.txt' 1000 10000
  fork_remote_dir="$TMP_ROOT/remote-fast-forward.git"
  publisher="$TMP_ROOT/remote-fast-forward-publisher"
  git clone --quiet --bare "$TEST_REPO" "$fork_remote_dir"
  git clone --quiet "file://$fork_remote_dir" "$publisher"
  git -C "$publisher" checkout --quiet -B main refs/remotes/origin/main
  mkdir -p "$publisher/recovery"
  printf 'upstream change\n' > "$publisher/recovery/upstream.txt"
  git -C "$publisher" add recovery/upstream.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm upstream-change
  git -C "$publisher" push --quiet origin main
  git -C "$publisher" fetch --quiet origin main
  current_ref=$(git -C "$publisher" rev-parse origin/main)
  git -C "$TEST_REPO" fetch --quiet "file://$fork_remote_dir" refs/heads/main:refs/remotes/test-current/main
  git -C "$TEST_REPO" checkout --quiet fm/task
  git -C "$TEST_REPO" merge --quiet --ff-only refs/remotes/test-current/main
  git -C "$TEST_REPO" branch -D main >/dev/null
  git -C "$TEST_REPO" remote add origin https://github.com/Ivory2024/firstmate.git
  (
    . "$ROOT/bin/fm-git-base-lib.sh"
    FM_GIT_BASE_MODE=remote
    FM_GIT_BASE_REPOSITORY=Ivory2024/firstmate
    FM_GIT_BASE_REF=refs/heads/main
    FM_GIT_BASE_SHA=$TEST_BASE
    fm_git_base_write_branch_pin "$TEST_REPO" fm/task "$TEST_BASE"
  ) || fail "could not record remote-mode branch identity in the fixture"
  FM_TEST_GIT_FETCH_URL=$fork_remote_dir
  export FM_TEST_GIT_FETCH_URL
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a remote fast-forward passed without a local main ref"
  assert_contains "$out" "inherited=1 verified_current_base=$current_ref" \
    "remote fast-forward refusal did not use the independently fetched current fork main"
  pass "remote ownership check rejects fast-forward with local main absent"
}

test_newline_filename_stays_one_scope_path() {
  local out status path
  new_case newline-filename
  mkdir -p "$TEST_REPO/recovery"
  path=$'recovery/allowed\nsecret.txt'
  printf 'disallowed filename\n' > "$TEST_REPO/$path"
  commit_all newline-filename
  printf 'recovery/allowed\t2000\nsecret.txt\t2000\n@total\t5000\n' > "$TEST_SCOPE"
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a newline filename split across allowed path fragments passed scope validation"
  assert_contains "$out" 'scope allowlist invariant failed' \
    "newline filename refusal did not name the violated scope invariant"
  pass "a newline filename remains one path through scope validation"
}

test_existing_open_pr_for_task_branch_is_rejected() {
  local out status
  new_case conflicting-pr
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  printf 'count: 1 of 1 total\npull_requests[1]{number,title,state,author,draft,review}:\n  42,"Existing PR",open,Ivory2024,no,none\n' > "$TEST_PR_LIST"
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "an already-open PR for the task branch passed the conflict guard"
  assert_contains "$out" 'conflicting open PR invariant failed: matching open PR count=1 numbers=42 repository=Ivory2024/firstmate' \
    "guard did not explain the matching open PR count and number"
  pass "an existing open PR for the task branch is refused before publication"
}

test_malformed_pr_count_fails_closed() {
  local out status
  new_case malformed-pr-count
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  printf 'count: many\npull_requests[]: []\n' > "$TEST_PR_LIST"
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a malformed gh-axi PR count passed the publish guard"
  assert_contains "$out" 'gh-axi did not report a parseable open-PR count' \
    "malformed PR count refusal did not name the failed invariant"
  pass "a malformed gh-axi count fails closed"
}

test_legitimate_large_scoped_recovery_change_passes() {
  local out status i
  new_case large-recovery
  # One explicit path pattern and a byte budget allow large legitimate recovery
  # work; there is no file-count ceiling.
  write_scope 'recovery/*.md' 1000 1000000
  mkdir -p "$TEST_REPO/recovery"
  i=1
  while [ "$i" -le 120 ]; do
    printf 'recovery note %s\n' "$i" > "$TEST_REPO/recovery/change-$i.md"
    i=$((i + 1))
  done
  commit_all large-scoped-recovery
  out=$(run_guard); status=$?
  expect_code 0 "$status" "a legitimate large scoped recovery change should pass explicit budgets"$'\n'"$out"
  assert_contains "$out" 'paths=120' "guard did not count all scoped paths"
  assert_contains "$out" 'unexpected=0' "large scoped change was not based only on task commits"
  pass "a 120-path scoped recovery change passes explicit byte budgets"
}

test_bare_zero_count_with_empty_list_passes() {
  local out status
  new_case bare-zero-count
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  printf 'count: 0\npull_requests: []\n' > "$TEST_PR_LIST"
  out=$(run_guard); status=$?
  expect_code 0 "$status" "a bare zero count with an empty list should pass"$'\n'"$out"
  pass "bare zero count and empty PR list pass validation"
}

test_malformed_pr_list_envelope_fails_closed() {
  local out status
  new_case malformed-pr-envelope
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  printf 'count: 0 (showing first 0)\nunexpected: []\n' > "$TEST_PR_LIST"
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "an invalid PR list envelope passed as empty"
  assert_contains "$out" 'gh-axi PR list envelope or rows are malformed' \
    "invalid PR envelope refusal did not name the failed invariant"
  pass "an invalid empty-list envelope fails closed"
}

test_malformed_pr_row_fails_closed() {
  local out status
  new_case malformed-pr-row
  write_scope 'recovery/*.txt' 1000 5000
  mkdir -p "$TEST_REPO/recovery"
  printf 'task change\n' > "$TEST_REPO/recovery/fix.txt"
  commit_all scoped-fix
  printf 'count: 1 of 1 total\npull_requests[1]{number,title,state}:\n  malformed row\n' > "$TEST_PR_LIST"
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a malformed PR row passed the list validation"
  assert_contains "$out" 'gh-axi PR list envelope or rows are malformed' \
    "invalid PR row refusal did not name the failed invariant"
  pass "a malformed PR table row fails closed"
}

test_correct_base_scoped_delta_passes
test_linked_worktrees_keep_private_base_pins
test_hundreds_of_inherited_paths_are_rejected_by_scope
test_oversized_scoped_file_is_rejected
test_pathspec_magic_filename_obeys_byte_budget
test_unexpected_merged_commits_are_rejected
test_fast_forwarded_base_commits_are_rejected
test_remote_fast_forward_rejected_without_local_main
test_newline_filename_stays_one_scope_path
test_existing_open_pr_for_task_branch_is_rejected
test_malformed_pr_count_fails_closed
test_legitimate_large_scoped_recovery_change_passes
test_bare_zero_count_with_empty_list_passes
test_malformed_pr_list_envelope_fails_closed
test_malformed_pr_row_fails_closed

echo '# all fm-publish-guard tests passed'
