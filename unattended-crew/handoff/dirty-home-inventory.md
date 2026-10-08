# Operational home dirty-file inventory, preservation and rollback plan (P5)

**Read-only analysis.** No backup of the operational home was created and no home
file was modified, per the mandate. This document records metadata only; it is
deliberately **not** a restorable copy of the changes.

- Home: `/Users/irene/Developer/kunchenguid_repos/firstmate`
- Branch / HEAD: `fix/ci-flake-watcher-lock-hup` @ `5f4a1028`
- Tracked-dirty count: **13** (9 modified tracked + 4 untracked)
- Fingerprint before/after all batch phases:
  `0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8`

The working tree is on a **feature branch, not `main`** (the pre-existing
worktree-tangle condition, unrelated to this batch and unchanged by it). These
changes predate the batch and belong to the branch `fix/ci-flake-watcher-lock-hup`
(watcher lock / OpenCode plugin lifecycle / Codex quota wake resume work).

## 1. File-by-file inventory

`source/ownership` is `UNKNOWN` where it could not be verified (not guessed).
`ops relevance` = relevance to G4 operational apply; `G4 conflict` = chance a G4
apply touches the same surface.

| # | Path | Git | Change (short) | Source/owner | Ops relevance | G4 conflict | Preserve | Recover | Recover verify | Unresolved risk |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `.gitignore` | M (+1) | add `config/`-area ignore line at :24 | UNKNOWN | low | low | keep as-is | `git checkout -- .gitignore` only if intended | `git diff --quiet .gitignore` | none |
| 2 | `.opencode/plugins/fm-primary-cd-check.js` | M (+16) | 16 added lines after `FmPrimaryCdCheck` | UNKNOWN | high | high | keep as-is | `git checkout -- <f>` | re-run `tests/fm-opencode-watch-arm-plugin-export.test.sh` | plugin loader contract |
| 3 | `.opencode/plugins/fm-primary-pretool-check.js` | M (+16) | 16 added lines after `FmPrimaryPretoolCheck` | UNKNOWN | high | high | keep as-is | same | same | plugin loader contract |
| 4 | `.opencode/plugins/fm-primary-sessionstart-nudge.js` | M (+30/-1) | export shape + added block | UNKNOWN | high | high | keep as-is | same | same | plugin loader contract |
| 5 | `.opencode/plugins/fm-primary-turnend-guard.js` | M (+30/-1) | export shape + added block | UNKNOWN | high | high | keep as-is | same | same | plugin loader contract |
| 6 | `.opencode/plugins/fm-primary-watch-arm.js` | M (+130/-15) | arm readiness/recovery rework | UNKNOWN | **highest** | **highest** | keep as-is | same | plugin export test + watcher arm smoke | watcher auto re-arm |
| 7 | `bin/fm-watch-arm.sh` | M (+33/-5) | HUP cleanup / child temp output | UNKNOWN | **highest** | **highest** | keep as-is | `git checkout -- bin/fm-watch-arm.sh` | `tests/fm-watcher-lock.test.sh` | arm HUP path |
| 8 | `bin/fm-watch.sh` | M (+25/-10) | heartbeat scan + event wait | UNKNOWN | high | high | keep as-is | `git checkout -- bin/fm-watch.sh` | `tests/fm-watcher-lock.test.sh` | heartbeat/event loop |
| 9 | `tests/fm-watcher-lock.test.sh` | M (+18/-1) | new lock/arm assertions | UNKNOWN | test | high | keep as-is | `git checkout -- <f>` | run the file | none |
| 10 | `.opencode/plugins/lib/fm-opencode-lifecycle-adapter.js` | ?? | new 2068 B lifecycle adapter | UNKNOWN | high | high | keep as-is | recreate from branch work | plugin export test | untracked (not in any commit) |
| 11 | `bin/fm-check-quota-condition.sh` | ?? | new 151 B quota time check | UNKNOWN | medium | medium | keep as-is | recreate | `sh -n` | untracked |
| 12 | `bin/fm-quota-wake-resume.sh` | ?? | new 4503 B quota wake resume | UNKNOWN | high | high | keep as-is | recreate | `bash -n` + dry run | untracked |
| 13 | `tests/fm-opencode-watch-arm-plugin-export.test.sh` | ?? | new 2135 B loader-contract test | UNKNOWN | test | high | keep as-is | recreate | run the file | untracked |

SHA-256 of the current working-tree contents (verification anchor for recovery):

```
13e6f383e:  .gitignore
23046d684:  .opencode/plugins/fm-primary-cd-check.js
ea2544112:  .opencode/plugins/fm-primary-pretool-check.js
74ecfb018:  .opencode/plugins/fm-primary-sessionstart-nudge.js
3645df3df:  .opencode/plugins/fm-primary-turnend-guard.js
8e42c1b8b:  .opencode/plugins/fm-primary-watch-arm.js
dc800e804:  bin/fm-watch-arm.sh
b1a760ce3:  bin/fm-watch.sh
4a5e788d9:  tests/fm-watcher-lock.test.sh
cb345e967:  .opencode/plugins/lib/fm-opencode-lifecycle-adapter.js
28132df7e:  bin/fm-check-quota-condition.sh
8e635d899:  bin/fm-quota-wake-resume.sh
dc17cbdb6:  tests/fm-opencode-watch-arm-plugin-export.test.sh
```

Note: `git stash list` holds 3 unrelated older stashes; none is relied on here.

## 2. Preservation plan (design only — not executed)

The mandate forbids creating operational-home backups, so this is the plan a
future approved run would follow:

1. **Freeze evidence of current state (metadata only, done):** `git status
   --porcelain=v1`, `git diff --numstat`, per-file SHA-256 (above), branch/HEAD,
   and the fingerprint hash — all recorded in this doc.
2. **Snapshot before any apply (future):** `git -C <home> stash push -u -m
   "g4-preapply"` **or** `git -C <home> diff > <evidence>/preapply.patch` plus a
   copy of the 4 untracked files into a **non-home** evidence directory (never
   under the operational home). The stash path is reversible with `git stash
   apply`; the patch path is reversible with `git apply`.
3. **Verify the snapshot:** re-hash the snapshot; compare to the SHA-256 table
   above; confirm the untracked 4 are present.
4. **Conflict analysis before G4:** because items 2–12 are watcher/plugin/quota
   runtime surfaces and G4 apply touches the same watcher machinery, G4 must be
   planned to land **on top of, or after**, this branch — never by resetting the
   branch to `main`. Any `git checkout main` / `git clean` in the home is
   forbidden until this branch's work is landed or explicitly preserved.
5. **Apply-time gate:** G4 apply must refuse if the fingerprint differs from the
   recorded pre-apply snapshot, or if the home is not on the expected branch.

## 3. Rollback plan (scenarios)

Recovery primitive: `git -C <home> apply -R <patch>` / `git stash apply` for the
tracked files, and restore the 4 untracked files from the non-home snapshot.
Never `git reset --hard` / `git clean -fd` (would destroy uncommitted work).

| # | Scenario | Detect | Stop condition | Restore targets | Order | Verify | Success | On failure |
|---|---|---|---|---|---|---|---|---|
| 1 | abort before apply | operator call | — | nothing (no change) | — | fingerprint == recorded | fingerprint unchanged | report and hold |
| 2 | apply failed partway | apply nonzero; fingerprint changed | any nonzero apply | all 9 tracked + 4 untracked | reverse patch, then restore untracked | fingerprint == recorded | exact fingerprint | hold; do not retry blindly |
| 3 | post-apply service start fails | launchd/tmux start rc != 0 | start failure | watcher scripts + plugins | reverse patch | watcher arm smoke test | arm starts, lock clean | hold, escalate |
| 4 | watcher/scheduler misbehaves | heartbeat frozen; arm churn | repeated re-arm | `bin/fm-watch*.sh` + plugins | reverse patch of items 6–8 | `tests/fm-watcher-lock.test.sh` | test green + steady heartbeat | hold |
| 5 | credential/env conflict | config load error | credential touch required | never touch credentials | stop | — | n/a | escalate (credential change needs explicit approval) |
| 6 | collision with dirty files | patch rejects hunks | any rejected hunk | reconcile file-by-file | re-apply with 3-way | fingerprint + targeted tests | all hunks applied | hold |
| 7 | rollback itself fails | reverse patch/restore nonzero | any nonzero | manual per-file restore | untracked first, then tracked | fingerprint == recorded | exact fingerprint | hold; escalate immediately |

Invariant across all scenarios: **never** force, stash-discard, or clean the
home; uncommitted work is preserved by construction.

## 4. G4 implication

Because the dirty set is concentrated exactly on the runtime surfaces G4 would
apply (watcher, arm plugins, quota resume), G4 apply carries a **high conflict
risk** until this branch's work is landed or explicitly preserved. This is the
single strongest reason G4 is not a plain apply-and-go.
