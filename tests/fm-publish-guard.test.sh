#!/usr/bin/env bash
# Regression tests for the pinned-base publish guard and task branch creation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-publish-guard)
FAKEBIN="$TMP_ROOT/fakebin"
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

new_case() { # <name>
  local name=$1
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
  git -C "$TEST_REPO" config firstmate.baseRef refs/heads/main
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
  printf 'count: 0\npull_requests: []\n' > "$TEST_PR_LIST"
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
  (cd "$TEST_REPO" && PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-publish-guard.sh" check 2>&1)
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
  new_case fast-forwarded-base
  write_scope 'recovery/*.txt' 1000 10000
  mkdir -p "$TEST_REPO/recovery"
  printf 'upstream change\n' > "$TEST_REPO/recovery/upstream.txt"
  commit_all upstream-change
  git -C "$TEST_REPO" branch -f main HEAD
  git -C "$TEST_REPO" reset --hard main >/dev/null
  out=$(run_guard); status=$?
  [ "$status" -ne 0 ] || fail "a task branch fast-forwarded to newer base passed the ownership guard"
  assert_contains "$out" "already reachable from 'refs/heads/main'" \
    "fast-forward refusal did not identify commits inherited from the moving base"
  pass "a fast-forwarded newer base commit is rejected despite scoped paths"
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

test_correct_base_scoped_delta_passes
test_linked_worktrees_keep_private_base_pins
test_hundreds_of_inherited_paths_are_rejected_by_scope
test_oversized_scoped_file_is_rejected
test_unexpected_merged_commits_are_rejected
test_fast_forwarded_base_commits_are_rejected
test_existing_open_pr_for_task_branch_is_rejected
test_legitimate_large_scoped_recovery_change_passes

echo '# all fm-publish-guard tests passed'
