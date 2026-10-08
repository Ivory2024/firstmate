# Unattended guard canary: tests/ structure survey

Method: ran four read-only commands in the task worktree (disposable git worktree of firstmate, detached HEAD on a clean default branch) and copied each printed number verbatim, without computing anything by hand: `ls tests/*.sh | wc -l`, `ls tests/*.test.sh | wc -l`, `ls tests/*.sh | grep -v '\.test\.sh$' | wc -l`, and `bin/fm-test-run.sh --list-families | wc -l`. No tracked file was modified; the survey is read-only.

StructClaim: test_sh = 244
StructClaim: test_test_sh = 234
StructClaim: helpers = 10
StructClaim: families = 15
