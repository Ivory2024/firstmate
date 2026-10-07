#!/usr/bin/env bash
# Regression test for the OpenCode v2 plugin entrypoint and hook registration contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out=$(node --input-type=module - "$ROOT" 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const { consumeEventStream } = await import(pathToFileURL(`${root}/.opencode/plugins/lib/fm-event-stream.js`).href);
const streamController = new AbortController();
let streamSubscriptions = 0;
let streamFailures = 0;
const streamTask = consumeEventStream({
  subscribe: ({ signal }) => {
    streamSubscriptions += 1;
    if (streamSubscriptions === 1) return (async function* () { yield { type: "fixture.event" }; })();
    return (async function* () {
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
    })();
  },
  signal: streamController.signal,
  onEvent: async () => {},
  onFailure: () => { streamFailures += 1; },
});
await waitFor(() => streamSubscriptions >= 2);
assert.equal(streamFailures, 1, "a cleanly terminated event stream is observable and re-subscribed");
streamController.abort();
await streamTask;

const plugins = [
  ["fm-primary-cd-check.js", "fm-primary-cd-check", "tool"],
  ["fm-primary-pretool-check.js", "fm-primary-pretool-check", "tool"],
  ["fm-primary-sessionstart-nudge.js", "fm-primary-sessionstart-nudge", "event"],
  ["fm-primary-turnend-guard.js", "fm-primary-turnend-guard", "event"],
  ["fm-primary-watch-arm.js", "fm-primary-watch-arm", "event"],
];

for (const [filename, id, domain] of plugins) {
  const moduleUrl = pathToFileURL(`${root}/.opencode/plugins/${filename}`);
  const plugin = (await import(moduleUrl.href)).default;
  assert.equal(typeof plugin?.id, "string", `${filename} has a default id`);
  assert.equal(plugin.id, id, `${filename} exports its stable plugin id`);
  assert.equal(typeof plugin?.setup, "function", `${filename} has a v2 setup function`);

  const registrations = [];
  let eventDrained = false;
  const events = [];
  const ctx = {
    location: { directory: "" },
    session: { prompt: async () => {} },
    tool: {
      hook: async (name, callback) => registrations.push({ domain: "tool", name, callback }),
    },
    event: {
      subscribe: ({ signal } = {}) => (async function* () {
        while (events.length && !signal?.aborted) yield events.shift();
        if (!signal?.aborted) {
          eventDrained = true;
          await new Promise((resolve) => signal?.addEventListener("abort", resolve, { once: true }));
        }
      })(),
    },
  };

  const cleanup = await plugin.setup(ctx);
  if (domain === "tool") {
    assert.deepEqual(registrations.map(({ name }) => name), ["execute.before"], `${filename} registers its v2 tool hook`);
  } else {
    for (let i = 0; i < 50 && !eventDrained; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(eventDrained, true, `${filename} subscribes through the v2 event domain`);
  }
  await cleanup?.();
}

const fixture = mkdtempSync(join(root, ".opencode-event-contract-"));
const savedFmEnv = Object.fromEntries(["FM_HOME", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_STATE_OVERRIDE"].map((key) => [key, process.env[key]]));
try {
  mkdirSync(join(fixture, "bin"), { recursive: true });
  mkdirSync(join(fixture, "state"), { recursive: true });
  mkdirSync(join(fixture, "config"), { recursive: true });
  writeFileSync(join(fixture, "AGENTS.md"), "fixture\n");
  execFileSync("git", ["init", "--quiet", fixture]);
  writeFileSync(join(fixture, "bin", "fm-supervision-lib.sh"), readFileSync(`${root}/bin/fm-supervision-lib.sh`));

  // The session-start hook is executable against a fixture nudge command.
  writeFileSync(join(fixture, "bin", "fm-sessionstart-nudge.sh"), "#!/bin/sh\nprintf 'fixture nudge'\n");
  chmodSync(join(fixture, "bin", "fm-sessionstart-nudge.sh"), 0o755);
  const createdPrompts = [];
  const createdEvents = [{ type: "session.created", data: { info: { id: "created-v2" } } }];
  const createdCtx = eventContext(fixture, createdEvents, createdPrompts);
  const stopCreated = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-sessionstart-nudge.js`).href + `?contract=${Date.now()}`)).default.setup(createdCtx);
  await waitFor(() => createdPrompts.length === 1);
  assert.equal(createdPrompts[0].sessionID, "created-v2", "session.created reads v2 data.info.id");
  await stopCreated();

  // The turn-end handler must pass v2 idle IDs into the shared arm coordinator.
  const armedSessions = [];
  globalThis.__firstmateOpenCodeWatchArm = { ensureArmed: async (sessionID) => { armedSessions.push(sessionID); return "armed"; } };
  const idleEvents = [{ type: "session.idle", data: { sessionID: "idle-turn-v2" } }];
  const turnCtx = eventContext(fixture, idleEvents, []);
  const stopTurn = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`).href + `?contract=${Date.now()}`)).default.setup(turnCtx);
  await waitFor(() => armedSessions.length === 1);
  assert.deepEqual(armedSessions, ["idle-turn-v2"], "turn-end guard forwards v2 data.sessionID");
  await stopTurn();

  // Watch-arm must launch from durable supervision state even when no session.idle event exists.
  writeFileSync(join(fixture, "config", "x-mode.env"), "\n");
  process.env.FM_HOME = fixture;
  process.env.FM_ROOT_OVERRIDE = fixture;
  process.env.FM_CONFIG_OVERRIDE = join(fixture, "config");
  process.env.FM_STATE_OVERRIDE = join(fixture, "state");
  writeFileSync(join(fixture, "state", ".lock"), String(process.pid));
  const armMarker = join(fixture, "arm-session");
  writeFileSync(join(fixture, "bin", "fm-watch-arm.sh"), `#!/bin/sh\nprintf '%s' "$1" > '${armMarker}'\nprintf 'watcher: started\\n'\nexec sleep 30\n`);
  chmodSync(join(fixture, "bin", "fm-watch-arm.sh"), 0o755);
  const watchEvents = [{ type: "session.step.started", data: { sessionID: "step-watch-v2" } }];
  const watchCtx = eventContext(fixture, watchEvents, []);
  const stopWatch = await (await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`).href + `?contract=${Date.now()}`)).default.setup(watchCtx);
  await waitFor(() => {
    try { return readFileSync(armMarker, "utf8") === "--restart"; } catch { return false; }
  });
  assert.equal(readFileSync(armMarker, "utf8"), "--restart", "watch-arm launches from durable state without waiting for session.idle");
  await stopWatch();

  const recoveryFixtures = [];
  const recoveryHooks = [];
  const savedRetryEnv = Object.fromEntries(["FM_WATCH_REARM_RETRY_BASE_MS", "FM_WATCH_REARM_RETRY_MAX_MS", "FM_WATCH_REARM_RETRY_LIMIT", "FM_OPENCODE_WATCH_HEALTH_RECHECK_MS"].map((key) => [key, process.env[key]]));
  const makeRecoveryFixture = (label, { meta = false, lock = true, wake = false, mode = "start" } = {}) => {
    const dir = mkdtempSync(join(root, `.opencode-recovery-${label}-`));
    recoveryFixtures.push(dir);
    mkdirSync(join(dir, "bin"), { recursive: true });
    mkdirSync(join(dir, "state"), { recursive: true });
    mkdirSync(join(dir, "config"), { recursive: true });
    writeFileSync(join(dir, "AGENTS.md"), "fixture\n");
    execFileSync("git", ["init", "--quiet", dir]);
    writeFileSync(join(dir, "bin", "fm-supervision-lib.sh"), readFileSync(`${root}/bin/fm-supervision-lib.sh`));
    writeFileSync(join(dir, "bin", "fm-wake-lib.sh"), readFileSync(`${root}/bin/fm-wake-lib.sh`));
    writeFileSync(join(dir, "bin", "fm-watch.sh"), "#!/bin/sh\nexit 0\n");
    writeFileSync(join(dir, "bin", "fm-watch-arm.sh"), [
      "#!/usr/bin/env bash",
      'count_file="$FM_HOME/state/arm-count"',
      'count=0; [ ! -f "$count_file" ] || count=$(cat "$count_file")',
      'count=$((count + 1)); printf "%s\\n" "$count" > "$count_file"',
      'if [ "$(cat "$FM_HOME/state/arm-mode" 2>/dev/null)" = fail-first ] && [ "$count" -eq 1 ]; then printf "watcher: FAILED - stale fixture\\n"; exit 1; fi',
      'if [ "$(cat "$FM_HOME/state/arm-mode" 2>/dev/null)" = always-fail ]; then printf "watcher: FAILED - fixture arm failure\\n"; exit 1; fi',
      'lock_dir="$FM_HOME/state/.watch.lock"; mkdir -p "$lock_dir"',
      'printf "%s\\n" "$FM_HOME" > "$lock_dir/fm-home"',
      'printf "%s\\n" "$FM_ROOT_OVERRIDE/bin/fm-watch.sh" > "$lock_dir/watcher-path"',
      '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"',
      'watcher_pid=$PPID',
      'printf "%s\\n" "$watcher_pid" > "$lock_dir/pid"',
      'fm_pid_identity "$watcher_pid" > "$lock_dir/pid-identity"',
      'touch "$FM_HOME/state/.last-watcher-beat"',
      'printf "watcher: started pid=%s (beacon fresh)\\n" "$watcher_pid"',
      "exec sleep 30",
      "",
    ].join("\n"));
    chmodSync(join(dir, "bin", "fm-watch-arm.sh"), 0o755);
    writeFileSync(join(dir, "state", "arm-mode"), mode);
    if (meta) writeFileSync(join(dir, "state", "active.meta"), "active\n");
    if (lock) writeFileSync(join(dir, "state", ".lock"), String(process.pid));
    else writeFileSync(join(dir, "state", ".lock"), "1");
    if (wake) writeFileSync(join(dir, "state", ".wake-queue"), "1\t1\tsignal\tfixture.status\tcheck: fixture\n");
    return dir;
  };
  const openWatchPlugin = async (dir, label) => {
    process.env.FM_HOME = dir;
    process.env.FM_ROOT_OVERRIDE = dir;
    process.env.FM_CONFIG_OVERRIDE = `${dir}/config`;
    process.env.FM_STATE_OVERRIDE = `${dir}/state`;
    const prompts = [];
    const client = { session: { promptAsync: async (request) => prompts.push(request.body.parts[0].text) } };
    const mod = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`).href + `?recovery=${label}-${Date.now()}`);
    const hooks = await mod.FmPrimaryWatchArm({ client, directory: dir, worktree: dir });
    recoveryHooks.push(hooks);
    return { hooks, prompts };
  };
  const armCount = (dir) => {
    try { return Number(readFileSync(join(dir, "state", "arm-count"), "utf8").trim() || "0"); }
    catch { return 0; }
  };
  try {
    process.env.FM_WATCH_REARM_RETRY_BASE_MS = "10";
    process.env.FM_WATCH_REARM_RETRY_MAX_MS = "20";
    process.env.FM_WATCH_REARM_RETRY_LIMIT = "2";
    process.env.FM_OPENCODE_WATCH_HEALTH_RECHECK_MS = "20";

    const absentDir = makeRecoveryFixture("absent");
    const absent = await openWatchPlugin(absentDir, "absent");
    await absent.hooks.event({ event: { type: "session.step.started", properties: { sessionID: "step-session" } } });
    writeFileSync(join(absentDir, "state", "active.meta"), "active\n");
    await waitFor(() => armCount(absentDir) === 1);
    assert.equal(armCount(absentDir), 1, "an absent watcher is armed from active work and a stable step event without session.idle");
    await absent.hooks.dispose();

    const staleDir = makeRecoveryFixture("stale", { meta: true, mode: "fail-first" });
    const retryErrors = [];
    const originalRetryError = console.error;
    console.error = (...args) => retryErrors.push(args.join(" "));
    const stale = await openWatchPlugin(staleDir, "stale");
    await waitFor(() => armCount(staleDir) >= 2);
    assert.equal(armCount(staleDir), 2, "a failed/stale arm is retried once and recovers");
    await stale.hooks.dispose();
    console.error = originalRetryError;
    assert.equal(retryErrors.some((line) => line.includes("continuity retry")), true,
      "a failed arm attempt is observable while recovery retries");

    const staleWatcherDir = makeRecoveryFixture("stale-watcher", { meta: true });
    const staleWatcher = await openWatchPlugin(staleWatcherDir, "stale-watcher");
    await waitFor(() => armCount(staleWatcherDir) === 1
      && existsSync(join(staleWatcherDir, "state", ".watch.lock", "pid-identity"))
      && existsSync(join(staleWatcherDir, "state", ".last-watcher-beat")));
    const beatPath = join(staleWatcherDir, "state", ".last-watcher-beat");
    utimesSync(beatPath, new Date(0), new Date(0));
    await new Promise((resolve) => setTimeout(resolve, 30));
    await staleWatcher.hooks.event({ event: { type: "session.step.ended", properties: { sessionID: "stale-session" } } });
    await waitFor(() => armCount(staleWatcherDir) === 2);
    assert.equal(armCount(staleWatcherDir), 2, "a stale heartbeat retires the tracked arm once and starts one healthy successor");
    await staleWatcher.hooks.dispose();

    const failedDir = makeRecoveryFixture("failed", { meta: true, mode: "always-fail" });
    const failureErrors = [];
    const originalFailureError = console.error;
    console.error = (...args) => failureErrors.push(args.join(" "));
    const failed = await openWatchPlugin(failedDir, "failed");
    await waitFor(() => failureErrors.some((line) => line.includes("continuity")));
    assert.equal(armCount(failedDir) >= 2, true, "the failed arm path makes a bounded retry");
    await failed.hooks.dispose();
    console.error = originalFailureError;
    assert.equal(failureErrors.some((line) => line.includes("watcher: FAILED")), true,
      `re-arm failure is observable: ${failureErrors.join(" | ")}`);

    const healthyDir = makeRecoveryFixture("healthy", { meta: true });
    const healthy = await openWatchPlugin(healthyDir, "healthy");
    await waitFor(() => armCount(healthyDir) === 1);
    for (let i = 0; i < 12; i += 1) {
      await healthy.hooks.event({ event: { type: "session.step.started", properties: { sessionID: "healthy-session" } } });
      writeFileSync(join(healthyDir, "state", "repeat.turn-ended"), String(i));
      writeFileSync(join(healthyDir, "state", "repeat.status"), String(i));
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(armCount(healthyDir), 1, "healthy watcher and repeated event/turn-end triggers do not spawn duplicate arms");
    await healthy.hooks.dispose();

    const wakeDir = makeRecoveryFixture("wake", { wake: true });
    const wake = await openWatchPlugin(wakeDir, "wake");
    await waitFor(() => armCount(wakeDir) === 1);
    assert.equal(readFileSync(join(wakeDir, "state", ".wake-queue"), "utf8").includes("check: fixture"), true,
      "durable wake remains available to the normal watcher consumer after continuity arms");
    await wake.hooks.dispose();

    const noWorkDir = makeRecoveryFixture("no-work");
    const noWork = await openWatchPlugin(noWorkDir, "no-work");
    await noWork.hooks.event({ event: { type: "session.status", properties: { sessionID: "idle-session" } } });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(armCount(noWorkDir), 0, "idle/no-work OpenCode does not start a watcher or retry loop");
    await noWork.hooks.dispose();

    const contendedDir = makeRecoveryFixture("contended", { meta: true, lock: false });
    const contentionErrors = [];
    const originalError = console.error;
    console.error = (...args) => contentionErrors.push(args.join(" "));
    const contended = await openWatchPlugin(contendedDir, "contended");
    await contended.hooks.event({ event: { type: "session.step.started", properties: { sessionID: "contended-session" } } });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await contended.hooks.dispose();
    console.error = originalError;
    assert.equal(armCount(contendedDir), 0, "lock contention fails safe without spawning a watcher");
    assert.equal(contentionErrors.some((line) => line.includes("no longer owns the lock")), true, "lock refusal is observable");

    const reloadDir = makeRecoveryFixture("reload", { meta: true });
    const firstLoad = await openWatchPlugin(reloadDir, "reload-first");
    await waitFor(() => armCount(reloadDir) === 1);
    await firstLoad.hooks.dispose();
    const secondLoad = await openWatchPlugin(reloadDir, "reload-second");
    await waitFor(() => armCount(reloadDir) === 2);
    assert.equal(armCount(reloadDir), 2, "plugin reload re-arms from durable supervision state without a manual restart");
    await secondLoad.hooks.dispose();
  } finally {
    for (const hooks of recoveryHooks) await hooks.dispose();
    for (const [key, value] of Object.entries(savedRetryEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    for (const dir of recoveryFixtures) rmSync(dir, { recursive: true, force: true });
  }
} finally {
  for (const [key, value] of Object.entries(savedFmEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  delete globalThis.__firstmateOpenCodeWatchArm;
  rmSync(fixture, { recursive: true, force: true });
}

function eventContext(worktree, events, prompts) {
  return {
    location: { directory: worktree, worktree },
    session: { prompt: async (prompt) => prompts.push(prompt) },
    event: { subscribe: ({ signal } = {}) => (async function* () {
      for (const event of events) if (!signal?.aborted) yield event;
      if (!signal?.aborted) await new Promise((resolve) => signal?.addEventListener("abort", resolve, { once: true }));
    })() },
  };
}

async function waitFor(predicate) {
  for (let i = 0; i < 500 && !predicate(); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(predicate(), true, "expected observable event side effect");
}
EOF
) || fail "OpenCode plugins failed the v2 default-export/setup contract: $out"
[ -z "$out" ] || fail "OpenCode v2 plugin contract test printed output: $out"
pass "all five OpenCode plugins export v2 id/setup definitions and register through ctx domains"
