# Handoff: explicit Discord channel target

Updated: 2026-09-23 KST

## Result

- Discord channel ID `1551134713727426570` is now honored when explicitly configured, even though it is also the legacy default exclusion value.
- The live poll received two pending messages from that channel and both replies were posted successfully.
- Focused self-hosted Discord tests passed.

## Git

- Branch: `fix/discord-explicit-channel`.
- Commit: `465cdf12c28190eeb87030587b31631c61f90d09`.
- Remote: `Ivory2024/firstmate`.
- The branch is pushed and the worktree was clean before this handoff commit.

## Verification

- `tests/fm-discord-selfhosted.test.sh` passed.
- Targeted ShellCheck passed for the changed shell test.
- `node --check bin/fm-discord-poll.js` passed.
- `git diff --check` passed.
- Full repository lint was stopped after one shard exceeded ten minutes; changed-file checks passed.

## Continue

- Configure the same channel ID and bot token in the new laptop's private `.env`.
- Run the Firstmate Discord watcher so future polls are automatic.
- Open a PR from this branch if review is required.
