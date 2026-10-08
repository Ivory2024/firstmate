# P3 — Branch conflict resolution plan (READ-ONLY analysis)

Status: analysis only. **No merge, checkout, push, stash, reset, or clean was run.**
The operational home was inspected read-only; nothing under it was modified.

- Home: `/Users/irene/Developer/kunchenguid_repos/firstmate`
- Branch / HEAD: `fix/ci-flake-watcher-lock-hup` @ `5f4a1028`
- Dirty set: **13** files (9 modified tracked + 4 untracked) — unchanged, fingerprint
  `0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8`
- Relationship to `main`: `main` **is** an ancestor of HEAD; the branch adds exactly
  one commit (`5f4a1028 fix(discord): pass status_task_id to fm-discord-notify for
  perm-ask decisions`). No upstream is configured. vs `origin/main`: **10 behind, 1 ahead**.

## 1. What actually conflicts

The dirty set is concentrated on the runtime surfaces G4 would otherwise touch:

| Surface | Dirty files |
|---|---|
| watcher lock / arm | `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `tests/fm-watcher-lock.test.sh` |
| OpenCode arm plugins | `.opencode/plugins/fm-primary-watch-arm.js`, `…-cd-check.js`, `…-pretool-check.js`, `…-sessionstart-nudge.js`, `…-turnend-guard.js`, `.opencode/plugins/lib/fm-opencode-lifecycle-adapter.js` (new), `tests/fm-opencode-watch-arm-plugin-export.test.sh` (new) |
| quota wake resume | `bin/fm-quota-wake-resume.sh` (new), `bin/fm-check-quota-condition.sh` (new) |
| housekeeping | `.gitignore` (+1 line) |

The G4 mount itself writes **different file names** (`bin/fm-unattended*.sh`,
`config/unattended-crew.json`), so there is **no file-path collision** with the
dirty set. The conflict is (a) the home is on a **feature branch, not `main`**, and
(b) the dirty work is **uncommitted, owner UNKNOWN**, on the same *operational
machinery* (watcher/quota) G4 is about to bring under a controller. This is why the
G4 review returned `NO_GO` on exactly one condition: "operational-home conflict
unresolved".

## 2. Three paths compared

Legend: **Risk** = chance of harming unlanded work or the live watcher; **Workload**
= effort to reach a clean G4-apply state; **Verification** = what must pass before
the path is trusted; **Recovery** = how to undo if it goes wrong.

### Path A — land the existing branch through review, then apply G4

1. Commit the 13 dirty files onto `fix/ci-flake-watcher-lock-hup` (2 commits:
   watcher/arm-plugin, quota).
2. Rebase onto `origin/main` (10 behind) and resolve.
3. Open a PR, run CI + the watcher/plugin tests, land it.
4. Restore the home to `main`, then mount G4.

- **Risk: HIGH.** It requires committing work whose owner is UNKNOWN and whose
  intent is inferred from file names. A rebase 10 commits deep over the watcher
  surfaces can silently drop the arm-plugin rework. It also spends merge authority
  on work this batch did not author.
- **Workload: HIGH.** Author + review + CI + merge + rebase + a second apply step.
- **Verification:** `tests/fm-watcher-lock.test.sh`,
  `tests/fm-opencode-watch-arm-plugin-export.test.sh`, watcher arm smoke, full CI.
  None of these are currently authored/owned here, so their green is not evidence
  this batch can vouch for.
- **Recovery:** PR revert + re-derive the uncommitted work (only the recorded
  sha256s exist; the batch is forbidden from creating a home backup).
- **Blocks on:** the branch owner and captain merge approval.

### Path B — preserve the changes, build an isolated main-based candidate *(recommended)*

1. Preserve (metadata already recorded; on approval, a future run snapshots to a
   **non-home** dir: a patch for the 9 tracked files + copies of the 4 untracked).
2. Create an **isolated worktree** from `origin/main` (never the home).
3. Mount G4 there: `bin/fm-unattended*.sh`, `config/unattended-crew.json`,
   `EVIDENCE_ROOT`, quota/concurrency caps, free-model allow-list.
4. Verify with the full local suite + the mount rehearsal in a temp dir; run one
   bounded single-run canary from the mounted entrypoint.
5. Only after the candidate is green, ask for a **separate** approval to (a) land
   the preserved watcher branch through its owner, or (b) move the home to `main`,
   then apply G4 for real.

- **Risk: LOW.** The operational home is never written; the dirty work is preserved
  by construction (patch + untracked copies outside the home, hash-verified against
  the recorded table). The live watcher is untouched. The G4 candidate is built from
  a clean `main` base, so no tangle and no collision surface.
- **Workload: MEDIUM.** Snapshot + one worktree + mount + local tests. No foreign
  review or rebase is required to *reach a G4 candidate*.
- **Verification:** `bash tests/run-all.sh` (127/127), `bash verification/verify-local.sh`
  (16/16), `bin/fm-unattended-install.sh rehearse` (temp dir), one bounded real canary
  from the mounted entrypoint. The preserved home is verified by re-hashing the dirty
  set against the recorded sha256 table.
- **Recovery:** delete the candidate worktree; the home and its 13 dirty files were
  never touched. If the snapshot was ever applied, `git apply -R` restores tracked
  and the untracked copies are restored from the non-home dir.
- **Does not need:** any decision about the uncommitted work's fate, any merge, or
  any edit to the home.

### Path C — integrate G4 on top of the branch (in place)

Mount/wire G4 directly on the branch working tree (or a copy that includes the
uncommitted watcher/quota edits).

- **Risk: HIGHEST.** It edits the exact surfaces carrying unlanded work and the live
  watcher-lock change; a partial apply can clobber uncommitted edits. It builds on a
  base (`5f4a1028` + dirty) whose content is not yet committed, so any later
  cherry-pick/rebase loses the base.
- **Workload: HIGH.** Same authoring risk as A, plus the mount, with no isolation.
- **Verification:** would have to test the watcher *and* the controller together on
  the home — the one configuration the batch is explicitly forbidden to mutate.
- **Recovery: WEAKEST.** Uncommitted work is at direct risk; the only fallback is the
  sha256 table, and the batch may not create a home backup.
- **Rejected.**

## 3. Comparison table

| Path | Risk | Workload | Verification condition | Recovery |
|---|---|---|---|---|
| A land branch, then G4 | HIGH (foreign/unknown work, 10-deep rebase) | HIGH | watcher/plugin tests + CI + owner review | PR revert + re-derive dirty work |
| **B preserve + isolated main candidate** | **LOW** (home untouched) | **MEDIUM** | 127/127 suite + 16/16 local + rehearse + 1 canary | delete candidate; home never changed |
| C integrate on the branch | HIGHEST (edits dirty surfaces) | HIGH | combined watcher+controller on the home (forbidden) | weakest; uncommitted work at risk |

## 4. Recommendation

**Path B.** It is the only path that reaches a trustworthy G4 candidate **without
writing the operational home**, preserves the 13 dirty files by construction, and
keeps the live watcher untouched. It also defers the two decisions that need a human
(`land the watcher branch` and `move the home to main`) to separate, explicit
approvals. Path A remains a valid *later* merge decision by the branch owner; it is
not a prerequisite for building the candidate. Path C is rejected.

## 5. Guard rails for whichever path is approved later

- Never `git stash drop`, `git reset --hard`, or `git clean` in the home.
- G4 apply must refuse if the home fingerprint differs from the recorded one, or if
  the home is not on the expected branch.
- A preserved snapshot lives **outside** the home and is hash-verified before use.
- The launchd/watcher reload (if any) is a separate, explicitly approved action.

## 6. Commands actually run (read-only)

```
git -C <home> rev-parse --abbrev-ref HEAD        # fix/ci-flake-watcher-lock-hup
git -C <home> rev-parse HEAD                     # 5f4a1028...
git -C <home> status --porcelain=v1              # 13 files
git -C <home> merge-base --is-ancestor main HEAD # yes
git -C <home> log --oneline main..HEAD           # 1 commit
git -C <home> rev-list --left-right --count origin/main...HEAD  # 10 1
git -C <home> diff --numstat                     # 9 tracked modifications
```

No merge/checkout/push/stash/reset/clean was executed.
