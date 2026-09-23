# Handoff: remove Herdr backend support

Updated: 2026-09-23 KST

## Current result

- Codex validation was cancelled at the captain's request.
- The isolated worktree was preserved locally at `/Users/irene/.treehouse/firstmate-697ce1/1/firstmate`.
- Branch: `fm/firstmate-remove-herdr-backend-20260921`.
- Last commit: `6b3cef3b6bc86a37614802900ccdb3b63691c4a0`.

## Included changes

- Removed Herdr backend dispatch, lifecycle support, dedicated CI lane, and stale Herdr test expectations.
- Restored backend-neutral AFK launcher reconciliation and rollback helpers found missing during review.
- Preserved tmux and the other experimental backend paths.

## Verification boundary

- No-mistakes run: `01M3673XJ2763R94NZG7WWYZGE`.
- Rebase completed.
- Review found and auto-fixed three rounds of issues; the last review round was active when the run was cancelled.
- Test, document, lint, push, PR, and CI stages did not complete.
- No push or PR had been created at handoff time. Do not report this task as complete.

## Next operator action

Resume from this branch, finish the no-mistakes review, run tests/document/lint, then push only to `Ivory2024/firstmate` and open the PR. Do not merge.
