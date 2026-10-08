# P0 diagnostic: repeating Discord watcher-liveness alert

Read-only investigation. No wake queue drain/ack, no watcher start/stop, no launchd
change, no file modified. Only this report was written.

Alert under investigation (verbatim):
`HIGH reliability alert: durable wake queue is pending while watcher consumer is no-consumer (beacon grace 300s).`

Snapshot time: 2026-10-08 21:22:44 KST (epoch 1791462164).

---

## 1. Verdict

**FALSE_ALERT.**

A healthy watcher process held the lock throughout. The alert's `no-consumer`
classification is a deterministic false negative caused by the liveness-alert
producer running from a different checkout (slot 13) than the operational home it
monitors, so it compares the lock's recorded watcher path against the *wrong*
expected path and always concludes `no-consumer`.

The "durable wake queue is pending" half is literally true (queue has been
non-empty for ~7h12m), but pending-ness alone is normal durable state; it is not
evidence of a dead consumer here. The two halves together fire the alert hourly.

Caveat on scope: the watcher consumer is healthy; the queue backlog is a
separate, real condition (nothing is acknowledging the durable queue), but that
is not a watcher-consumer failure and is not what the message claims.

---

## 2. Actual pending queue count and oldest item wait

- Non-empty records at snapshot: **1070** (`state/.wake-queue`; growing ~1 per
  few seconds, was 1055→1065→1070 across the read).
- Sequence range: oldest `seq=5308`, newest `seq=6372` (`state/.wake-queue.seq`
  = 6372), i.e. 1065 contiguous rows then still growing.
- Oldest item: epoch **1791436249** = **2026-10-08 14:10:49 KST**.
- Oldest item wait at snapshot: **25915 s = 7 h 11 m 55 s**.
- Biggest duplicate producer: key `procevent:when-pr107-nm-resume:1` occupies
  **662** of the 1065 rows (~1 row / 38 s since 14:10). Other rows are the
  unattended canary turn-ended/status signals.

---

## 3. Last normal consumption time

The queue is append-only and is trimmed only by `bin/fm-wake-drain.sh
--ack-through`. The oldest surviving row is `seq=5308`, so the last
acknowledgement ever reached `seq=5307`.

**Last normal consumption ≈ 2026-10-08 14:10 KST (before the oldest row).** No
acknowledgement has happened for ~7h12m. This is the real backlog behind the
"pending" half of the message, and it is independent of watcher health.

---

## 4. Exact alert logic, and root cause

### 4.1 What decides `no-consumer` and the grace window

Producer: `/Users/irene/.treehouse/firstmate-697ce1/13/firstmate/bin/fm-watcher-liveness-alert.sh`
(launchd `dev.firstmate.watcher-liveness-alert`, `StartInterval 60`,
`FM_HOME`/`FM_ROOT_OVERRIDE` = `/Users/irene/Developer/kunchenguid_repos/firstmate`,
`FM_STATE_OVERRIDE` = that home's `state`, `FM_WATCHER_STALE_GRACE=300`).

Line 5:  `FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"`
Line 131 `classify_consumer()`:
```
pid=$(cat "$STATE/.watch.lock/pid" ...)
if ! fm_pid_alive "$pid" || ! fm_watcher_lock_matches_pid "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$pid" "$FM_HOME"; then
  printf 'no-consumer\n'
```
Line 134 is decisive: it passes **`$SCRIPT_DIR/fm-watch.sh`** as the expected
watcher path. `$SCRIPT_DIR` is the producer's own checkout
(`.../.treehouse/firstmate-697ce1/13/firstmate/bin`), not `$FM_ROOT/bin`.

Grace computation: later in `classify_consumer`, `age=$(fm_path_age
"$STATE/.last-watcher-beat")`; `age >= GRACE` => `stale-heartbeat`, else
`healthy`. `GRACE=${FM_WATCHER_STALE_GRACE:-...}=300`. The message text always
prints this 300 s grace. **The 300 s grace is not the bug and was never reached.**

`fm_watcher_lock_matches_pid` (identical in both checkouts; `fm-wake-lib.sh`
diff slot13 vs op-home = rc 0) requires four things:
```
[ "$lock_home"  = "$home" ]       # pass: fm-home = op home
[ "$lock_path"  = "$watch_path" ] # FAIL: op path vs slot13 expected
[ -n "$lock_identity" ]           # pass
[ "$current_identity" = "$lock_identity" ]  # pass: pid identity matches
```

The recorded lock watcher path is the **operational** path:
`cat state/.watch.lock/watcher-path` ->
`/Users/irene/Developer/kunchenguid_repos/firstmate/bin/fm-watch.sh`.

The expected path is the **slot 13** path. Mismatch => `no-consumer`.

### 4.2 Reproduction (read-only, no side effects)

Sourcing slot 13's `fm-wake-lib.sh` against the live operational lock:
```
pid=<live watcher pid> alive=yes
fm_watcher_lock_matches_pid "$STATE" "/Users/irene/.treehouse/firstmate-697ce1/13/firstmate/bin/fm-watch.sh" "$pid" "$HOME_"  -> rc=1   # no-consumer
fm_watcher_lock_matches_pid "$STATE" "/Users/irene/Developer/kunchenguid_repos/firstmate/bin/fm-watch.sh"      "$pid" "$HOME_"  -> rc=0   # healthy
```
So with the correct (home-derived) path the very same live watcher classifies
`healthy`; beat age was 46 s (< 300 s). The only failing predicate is the path.

### 4.3 Root cause

The launchd job runs the liveness-alert script out of the slot-13 worktree while
`FM_ROOT_OVERRIDE`/`FM_HOME` point at the operational home. The alert script's
own `WRITE` side (`install_agent`) renders `ProgramArguments` from `$SCRIPT_DIR`,
so once it is installed from a foreign checkout it permanently pins the job to
that checkout, while the monitored watcher is launched from `$FM_ROOT` (the
operational home). `classify_consumer` should derive the expected watcher path
from the home/code root it is monitoring (`$FM_ROOT/bin/fm-watch.sh`), not from
the script's own directory. It does not, so the classification is wrong whenever
`$SCRIPT_DIR/..` != `$FM_ROOT`.

Trigger half (why it repeats hourly, not once): the queue has been continuously
non-empty since 14:10, so `pending=true` on every 60 s check; `COOLDOWN=3600`
spaces re-emissions to hourly. Alert history from `state/x-context`
(discord-completion records) shows 22 high events, first 03:50:40 KST, latest
21:19:36 KST; the current episode's `high_since` = 1791436294 (14:11:34 KST).
**No `watcher-liveness-recovered` event exists at all** — consistent with a
classification that can never return healthy via the wrong path.

### 4.4 Producer checkout vs operational home

- Reserved producer: `.treehouse/firstmate-697ce1/13/firstmate`,
  branch `fm/discord-reaction-recovery-20261008` @ `fb5735eb`, **clean**.
  `bin/fm-watcher-liveness-alert.sh` and `tests/fm-watcher-liveness-alert.test.sh`
  are tracked there.
- Operational home: `fix/ci-flake-watcher-lock-hup` @ `5f4a1028`, **13 dirty**
  (9 M + 4 ??). `bin/fm-watcher-liveness-alert.sh` is **absent and untracked** here.
- `bin/fm-wake-lib.sh` is byte-identical between the two checkouts (diff rc 0),
  so the dirty/untracked watcher files (`bin/fm-watch.sh`, `bin/fm-watch-arm.sh`,
  OpenCode arm plugins, `bin/fm-quota-*.sh`) **do not change the alert
  classification logic**. They affect watcher runtime, not the liveness decode.

---

## 5. Per-hypothesis verdicts

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| A | Watcher process actually exited | **REJECTED** | Live `bash .../bin/fm-watch.sh` pid present; lock pid alive; `state/.watch-cycle-exits.log` shows continuous start/end with `successor=started:<pid>` every cycle, `exit_code=0`. |
| B | Watcher running but beacon update fails | **REJECTED** | `state/.last-watcher-beat` age 46 s < 300 s grace; beat mtime advances (21:19:14 at first read). |
| C | Watcher re-arm failed or looped | **REJECTED as cause** (observed benign churn) | Re-arm succeeds every cycle (`exit_code=0`, `reason=actionable-signal`, successor started within ~60 s). The ~60 s cycles come from an actionable signal each poll (canary turn-ends), not from a failed arm. No `watcher: FAILED` in the ledger. |
| D | Consumer did not return after quota resume | **REJECTED** | Untracked `bin/fm-quota-wake-resume.sh` / `bin/fm-check-quota-condition.sh` only `fm-send` to task ids and run a read-only Codex confirmation; they never start/stop the watcher. Queue oldest item is 14:10, not the 03:47 KST resume time. |
| E | Stale pending queue / stale state causes false positive | **PARTIAL** | The queue really is non-empty and stale-unacked (7h12m). But pending-ness is the trigger, not the false claim; the false claim is `no-consumer` while a healthy watcher holds the lock. |
| F | Multiple watcher instances / ownership mismatch | **REJECTED** | One live watcher + its arm wrapper. Old empty dirs `state/.watch.lock.steal.steal.steal.owner.*` (Sep 28) are inert. Lock symlink resolves to one owner dir `BKoz37` with matching pid/identity. |
| G | Alert condition / grace-window bug | **CONFIRMED (decisive)** | Expected watcher path is derived from `$SCRIPT_DIR` instead of `$FM_ROOT`; live reproduction gives rc=1 (slot13) vs rc=0 (operational). Grace window itself is correct. |

---

## 6. Correlation of alert emissions with real watcher state

- `dev.firstmate.watcher-liveness-alert` job: `runs=1050`, `last exit code=0`,
  `StartInterval=60`, job state `exited` (normal for an interval job).
- Local alert log `/Users/irene/Library/Logs/dev.firstmate.watcher-liveness-alert.log`
  is **0 bytes**: the script emits only to Discord (via
  `fm-discord-notify.sh`), not stdout/stderr, so no local alert history exists.
  History recovered from `state/x-context/discord-completion-*.json`.
- Emission times (KST): 03:50:40, then hourly 04:30–07:45 (episode
  `high_since` 03:50:39), brief resets 12:03/12:08/12:10/12:36/13:11 (queue
  empty-then-refill), then a sustained hourly series from 14:11:34 to the latest
  **21:19:36**.
- At every emission the watcher was alive and beating (cycle-exits ledger
  continuous; beat fresh at read time). The classification is deterministic and
  independent of watcher liveness, so it fired on schedule regardless.

---

## 7. Affected work scope

- **False-positive alerting only** — no work is actually unsupervised. The
  watcher process, singleton lock, beacon, and arm chain are healthy.
- **Operator trust/attention**: hourly false "reliability" pages since 03:50 KST.
- **Real but separate defect surfaced**: the durable queue is not being
  acknowledged (last ack ≤ seq 5307, ~14:10 KST), and one process-event watch
  (`when-pr107-nm-resume:1`) is spamming duplicate check rows (662×) — a
  producer flood, not a consumer failure.
- **Not affected**: project files, git state, secondmate homes, credentials.

---

## 8. Minimal fix file list

Primary (one line, in the checkout the launchd job executes):
1. `bin/fm-watcher-liveness-alert.sh` line 134 — pass the **home-derived**
   watcher path instead of the script-dir path:
   `fm_watcher_lock_matches_pid "$STATE" "$FM_ROOT/bin/fm-watch.sh" "$pid" "$FM_HOME"`
   (optionally `FM_WATCH_PATH` override, defaulting to `"$FM_ROOT/bin/fm-watch.sh"`).
   This file lives only on the slot-13 branch; it must land through that branch's
   normal review/owner path, or the feature must be re-homed onto the operational
   branch.

Supporting (not code):
2. Reinstall/reload the launchd job from the fixed copy
   (`fm-watcher-liveness-alert.sh install`), so the running job no longer points
   at a foreign checkout. This is a launchd change → approval required.
3. No change is needed to `bin/fm-wake-lib.sh` (identical, correct) or to the
   dirty `bin/fm-watch.sh` / `bin/fm-watch-arm.sh` (not part of the alert logic).

Queue hygiene (separate work items, not part of this fix):
4. Stop/quarantine the duplicate `procevent:when-pr107-nm-resume` producer.
5. Let the supervised firstmate session drain/ack the durable queue.

---

## 9. Required regression tests

Extend `tests/fm-watcher-liveness-alert.test.sh` (exists on the slot-13 branch):

1. **Cross-checkout classification**: `FM_ROOT_OVERRIDE`/`FM_STATE_OVERRIDE`
   pointing at home A while the script is invoked from checkout B, with A's
   healthy watcher lock (path = A's `bin/fm-watch.sh`) → `classify_consumer`
   must return `healthy` (fails on today's code).
2. **No false high alert**: healthy lock + non-empty queue → `check_liveness`
   must NOT emit `no-consumer` high (must not call `report`).
3. **Positive control**: no lock (or stale/absent beacon past `GRACE`) +
   non-empty queue → must emit `no-consumer` / `stale-heartbeat` respectively.
4. **Identity guard preserved**: lock present, pid recycled / identity mismatch →
   `no-consumer`.
5. **Recovery path**: sequence stale-lock (high emitted) → healthy lock →
   a `watcher-liveness-recovered` report is produced.

---

## 10. Safe recovery order (all gated on approval)

1. Confirm and record the false positive (this report) — no runtime change.
2. Fix the one line in the alert script on the branch that owns it; pass its
   regression tests. No operational-home, launchd, or queue action yet.
3. Get explicit captain approval for the **launchd** change, then reinstall/reload
   the job so it runs the fixed copy against the operational home.
4. Verify: force one `check`; confirm `classify_consumer` = `healthy` and that no
   new `watcher-liveness-...-high` record is written for > 1 cooldown window.
5. Separately, in an attended supervised firstmate session (never in this
   read-only diagnostic), drain/ack the durable queue and retire the duplicate
   `when-pr107-nm-resume` producer.

Never: `rm`/trim the queue by hand, `pkill -f bin/fm-watch.sh`, or disable the
alert as the fix.

---

## 11. Approvals needed for any operational change

- **launchd/plist change** (reinstall/reload `dev.firstmate.watcher-liveness-alert`)
  — explicit captain approval; standing boundary: watcher/scheduler/launchd.
- **Editing the slot-13 worktree / landing its branch** — owner + captain approval
  (foreign dirty-adjacent worktree; do not touch without it).
- **Wake queue drain/ack** — performed only by the supervised firstmate session;
  out of scope for this read-only diagnostic.
- **Retiring the duplicate procevent watch** — captain approval (changes runtime
  producer behavior).
- G4 operational apply remains separately gated (see §12).

---

## 12. Conflict with G4 preflight work, and independent fix feasibility

**G4 preflight (from `data/unattended-crew-orchestrator-20261008/handoff/`):**
`g4-operational-readiness-review.md` = `G4_NO_GO`, single blocker = "operational
home conflict": the home sits on `fix/ci-flake-watcher-lock-hup` @ `5f4a1028`
with 13 dirty files concentrated on the **watcher / arm-plugin / quota** runtime
surfaces (`bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `.opencode/plugins/*`,
`bin/fm-quota-*.sh`). `dirty-home-inventory.md` records the exact 13-file set and
a fingerprint (`0c4c59e1…`) that G4 apply must not disturb.

**Direct file overlap with the G4 dirty set: NONE.** The alert fix targets
`bin/fm-watcher-liveness-alert.sh`, which is **absent from the operational home
and not among the 13 dirty files**, plus the launchd job — no shared file.

**Runtime-path overlap: YES, indirect.** G4's boundary explicitly names
"watcher/scheduler/launchd changes," and the alert fix is exactly a launchd job
re-point plus a watcher-liveness script. Both operate on the same watcher
liveness machinery G4 must eventually reconcile.

**Independent fix possible: YES.** The defect is isolated to the alert producer
and its launchd binding. It can be fixed and landed without mounting the
unattended controller, without bringing the home to `main`, and without touching
any of the 13 dirty files. It must not alter the G4 fingerprint (it does not) and
its launchd reload needs explicit approval. Recommended sequencing: fix the
script on its branch and pass tests first; hold the launchd reload until the
captain approves, so it does not perturb G4's pre-apply snapshot window.
