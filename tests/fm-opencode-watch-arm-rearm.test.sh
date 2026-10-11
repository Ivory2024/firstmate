#!/usr/bin/env bash
# Regression test for the OpenCode watch-arm plugin's DURABLE-SIGNAL RE-ARM.
#
# Observed P0 (2026-10-11): a firstmate home's watcher was dead for 10h25m.
# state/.last-watcher-beat was 37506s stale and 1259 wakes had queued with no
# wake-driven supervision for the whole window. The tracked plugin armed
# supervision only from a quiescent session event, and OpenCode 2.0.26
# publishes no `session.idle` (observed 0x), so a session that stayed busy
# never armed the cycle at all.
#
# The plugin must arm from a durable on-disk signal that does not depend on any
# session event, and must still refuse to arm a second watcher when the cycle
# is healthy. Each case drives the REAL plugin in a plain Node host against a
# fake primary home and a recorder standing in for the arm:
#
#   A. no quiescent event ever, beacon missing  -> re-armed
#   B. no quiescent event ever, beacon fresh    -> NOT re-armed
#   C. no quiescent event ever, beacon stale    -> re-armed
#
# Case C is the observed outage shape exactly: the beacon existed and was far
# past the guard grace. Case A is the sharper one: a cycle that never beat at
# all, which the tracked event-driven arm could not recover from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
TMP_ROOT=$(fm_test_tmproot fm-opencode-watch-arm-rearm)
DRIVER="$TMP_ROOT/drive-rearm.mjs"

write_driver() {
  cat > "$DRIVER" <<'JS'
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync } from "node:fs";

const mod = await import(pathToFileURL(process.env.FM_TEST_PLUGIN).href);
const d = mod.default;
if (!d || typeof d !== "object" || Array.isArray(d) || typeof d.setup !== "function") {
  console.error("default export is not an OpenCode 2 {id, setup} definition");
  process.exit(2);
}
const home = process.env.FM_TEST_HOME;
const record = `${home}/state/arm-calls.log`;
let aborted = false;
const ctx = {
  location: { directory: home },
  session: { prompt: async () => ({}) },
  event: {
    subscribe({ signal } = {}) {
      return (async function* () {
        // A busy session: real traffic, and never a quiescent event.
        yield { type: "session.step.started", data: { sessionID: "ses_rearm_case" } };
        yield { type: "session.text.delta", data: { sessionID: "ses_rearm_case" } };
        await new Promise((resolve) => {
          if (signal?.aborted) return resolve();
          signal.addEventListener("abort", () => resolve(), { once: true });
        });
        aborted = true;
      })();
    },
  },
};
const cleanup = await mod.default.setup(ctx);
const deadline = Date.now() + Number(process.env.FM_TEST_WAIT_MS || "4000");
let armed = false;
while (Date.now() < deadline) {
  if (existsSync(record) && readFileSync(record, "utf8").trim()) {
    armed = true;
    break;
  }
  await new Promise((resolve) => setTimeout(resolve, 50));
}
cleanup?.();
if (!aborted) await new Promise((resolve) => setTimeout(resolve, 20));
console.log(armed ? "armed" : "quiet");
process.exit(0);
JS
}

# make_fake_home <dir>: a home the plugin accepts as a primary root, with the
# shared supervision predicate available and this test process recorded as the
# session-lock owner (the plugin walks the node host's ancestry to check that).
make_fake_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/state" "$home/config"
  git -C "$home" init -q
  : > "$home/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$home/bin/fm-supervision-lib.sh"
  : > "$home/state/rearm-case.meta"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$(dirname "${BASH_SOURCE[0]}")/../state/arm-calls.log"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=stub-rearm-1\n' "$$"
exec sleep 2
SH
  chmod +x "$home/bin/fm-watch-arm.sh"
}

# drive_case <name> <grace> <beacon>  -> prints "armed" or "quiet"
# <beacon> is "missing", "fresh", or "stale".
drive_case() {
  local name=$1 grace=$2 beacon=$3 home out rc
  home="$TMP_ROOT/$name"
  make_fake_home "$home"
  case "$beacon" in
    fresh) : > "$home/state/.last-watcher-beat" ;;
    stale) : > "$home/state/.last-watcher-beat"; touch -t 202001010000 "$home/state/.last-watcher-beat" ;;
  esac
  out="$TMP_ROOT/$name.out"
  # No command substitution here: the node host must stay a direct child of this
  # script so its ancestry check finds $$ in state/.lock.
  FM_TEST_PLUGIN="$PLUGIN" \
    FM_TEST_HOME="$home" \
    FM_TEST_WAIT_MS=4000 \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_GUARD_GRACE="$grace" \
    FM_OPENCODE_REARM_POLL_MS=200 \
    node "$DRIVER" > "$out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "$name: the plugin host exited $rc"; }
  printf '%s' "$(tail -n 1 "$out")"
}

# The shared predicate itself, so case B's "quiet" is proved to come from the
# healthy beacon rather than from a plugin that cannot arm at all.
# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

write_driver

# --- A: no quiescent event, no beacon at all --------------------------------
home_a="$TMP_ROOT/case-a"
got=$(drive_case case-a 300 missing)
assert_equals "armed" "$got" "case A: a busy session with no beacon must still re-arm supervision"
assert_contains "$(cat "$home_a/state/arm-calls.log")" "--restart" \
  "case A: the re-arm must drive bin/fm-watch-arm.sh through its restart path"
pass "case A: supervision is re-armed from the durable beacon with no session event at all"

# --- B: no quiescent event, beacon fresh (a healthy cycle) ------------------
home_b="$TMP_ROOT/case-b"
if fm_supervision_unhealthy "$home_b/state"; then
  fail "case B fixture is wrong: the shared predicate must call a fresh beacon healthy"
fi
got=$(drive_case case-b 300 fresh)
assert_equals "quiet" "$got" "case B: a fresh beacon means a healthy cycle, so no second watcher may be armed"
assert_absent "$home_b/state/arm-calls.log" \
  "case B: the plugin armed a watcher while a healthy cycle held a fresh beacon"
pass "case B: a healthy cycle is left alone; the plugin arms no second watcher"

# --- C: no quiescent event, beacon stale (the observed outage shape) --------
home_c="$TMP_ROOT/case-c"
got=$(drive_case case-c 1 stale)
assert_equals "armed" "$got" "case C: a stale beacon must re-arm supervision"
assert_contains "$(cat "$home_c/state/arm-calls.log")" "--restart" \
  "case C: the stale-beacon re-arm must drive bin/fm-watch-arm.sh through its restart path"
pass "case C: the 37506s-stale-beacon outage shape now re-arms itself"

echo "all fm-opencode-watch-arm-rearm tests passed"
