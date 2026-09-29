import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { subscribeEvents, TURN_END_EVENTS, watchArmCoordinatorKey } from "./lib/fm-opencode-events.js";
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const ARM_READY_TIMEOUT_DEFAULT_MS = process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

const instances = new Map();

function createInstance() {
  return {
    generation: 0, child: null, armStatus: "idle", retryTimer: null,
    retryFailures: 0, launchInFlight: null, restorationInFlight: null,
    armClose: new WeakMap(), armReadiness: new WeakMap(), armRecovery: new WeakMap(),
  };
}

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(state, status) {
  state.armStatus = status;
}

function waitForArmReady(state, armChild) {
  const readiness = state.armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), ARM_READY_TIMEOUT_MS);
    timer.unref();
    void readiness.then((status) => {
      clearTimeout(timer);
      resolve(status);
    });
  });
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  try {
    return readdirSync(paths.state).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

async function sessionOwnsLock(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    const result = await runProcess("ps", ["-o", "ppid=", "-p", pid]);
    if (result.code !== 0) return false;
    pid = result.stdout.trim();
    if (!pid || pid === "1") return false;
  }
  return false;
}

function classifyArmClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  const reason = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(state, stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line))) {
    setArmStatus(state, "wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus(state, "armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus(state, "external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus(state, "failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(paths, ctx, sessionID, text) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  await ctx.session.prompt({ sessionID, text: encoded });
}

function confirmHandlingDelivery(paths, recovery) {
  try {
    const result = spawnSync(
      "bash",
      [`${paths.root}/bin/fm-watch-arm.sh`, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
      {
        cwd: paths.root,
        encoding: "utf8",
        env: { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state, FM_ROOT_OVERRIDE: paths.root },
      },
    );
    if (result.status === 0) return { ok: true, detail: "" };
    const stderr = String(result.stderr || "").trim();
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${String(error?.message ?? error)}`,
    };
  }
}

function confirmHandlingDeliveryWithRetry(state, paths, recovery) {
  const snapshot = () => state.armRecovery.get(state.child) ?? recovery;
  const first = confirmHandlingDelivery(paths, snapshot());
  if (first.ok) return first;
  return confirmHandlingDelivery(paths, snapshot());
}

async function deliverActionableWake(state, paths, ctx, sessionID, message, recovery) {
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(state, paths, recovery);
    if (!confirmed.ok) {
      if (recovery.watcherPid) {
        try {
          process.kill(Number(recovery.watcherPid), 0);
        } catch {
          await retireArm(state, state.child);
        }
      }
      await sendPrompt(paths, ctx, sessionID, wakePrompt(`${message}\n\n${confirmed.detail}`));
      return;
    }
  }
  await sendPrompt(paths, ctx, sessionID, wakePrompt(message));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(paths, ctx, sessionID, reason) {
  void sendPrompt(paths, ctx, sessionID, wakePrompt(reason)).catch(() => {
    // OpenCode owns delivery errors; continuity restoration never waits on prompting.
  });
}

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function waitForRetry(attempt) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, retryDelay(attempt));
    timer.unref();
  });
}

async function retireArm(state, armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = state.armClose.get(armChild);
  if (!closed) return false;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ARM_RETIRE_TIMEOUT_MS);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function restorationFailure(status) {
  if (status === "read-only") {
    return "watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock";
  }
  return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
}

async function restoreAfterActionableClose(state, paths, sessionID, ctx, predecessorArmPid, generation) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    if (!instanceIsActive(state, generation)) return { failure: "" };
    const { status, armChild } = await ensureArm(state, paths, sessionID, ctx, predecessorArmPid, true, generation);
    if (status === "armed") return { failure: "", recovery: state.armRecovery.get(armChild) };
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return { failure: "", recovery: state.armRecovery.get(armChild) };
    failure = restorationFailure(status);
    if (!(await retireArm(state, armChild))) {
      setArmStatus(state, "failed");
      return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms` };
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus(state, "failed");
  return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries` };
}

async function scheduleRetry(state, paths, sessionID, ctx, reason, predecessorArmPid, generation) {
  if (!instanceIsActive(state, generation)) return;
  if (state.child || state.retryTimer) return;
  if (!(await sessionOwnsLock(paths))) {
    if (!instanceIsActive(state, generation)) return;
    setArmStatus(state, "failed");
    surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  state.retryFailures += 1;
  if (state.retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus(state, "failed");
    surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus(state, "retrying");
  const timer = setTimeout(() => {
    if (state.retryTimer === timer) state.retryTimer = null;
    if (!instanceIsActive(state, generation)) return;
    void ensureArm(state, paths, sessionID, ctx, predecessorArmPid, false, generation).then((status) => {
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    }).catch(() => {
      // A rejected retry must not become an unhandled rejection that outlives the turn.
    });
  }, retryDelay(state.retryFailures));
  timer.unref();
  state.retryTimer = timer;
}

function spawnArm(state, paths, sessionID, ctx, predecessorArmPid, generation) {
  setArmStatus(state, "starting");
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
    FM_CONFIG_OVERRIDE: paths.config,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  const armChild = spawn("bash", ["-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" --restart'], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  state.child = armChild;
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  state.armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  state.armClose.set(armChild, closed);
  const releaseChild = () => {
    if (state.child === armChild) state.child = null;
  };
  const observeRecovery = () => {
    const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) state.armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeRecovery();
    observeArmOutput(state, stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeRecovery();
    observeArmOutput(state, stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "actionable") {
      if (state.restorationInFlight) return;
      state.retryFailures = 0;
      setArmStatus(state, "wake");
      const restoration = restoreAfterActionableClose(state, paths, sessionID, ctx, predecessor, generation);
      state.restorationInFlight = restoration;
      void restoration.then(async (result) => {
        try {
          const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
          await deliverActionableWake(state, paths, ctx, sessionID, message, result.recovery);
        } finally {
          if (state.restorationInFlight === restoration) state.restorationInFlight = null;
        }
      }).catch((error) => {
        if (state.restorationInFlight === restoration) state.restorationInFlight = null;
        surfaceFailure(
          paths,
          ctx,
          sessionID,
          `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
        );
      });
      return;
    }
    if (state.restorationInFlight) {
      setArmStatus(state, "failed");
      return;
    }
    void scheduleRetry(state, paths, sessionID, ctx, classification.message, predecessor, generation).catch(() => {
      // A rejected retry must not become an unhandled rejection that outlives the turn.
    });
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (state.restorationInFlight) {
      setArmStatus(state, "failed");
      return;
    }
    void scheduleRetry(
      state,
      paths,
      sessionID,
      ctx,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
      generation,
    ).catch(() => {
      // A rejected retry must not become an unhandled rejection that outlives the turn.
    });
  });
  return armChild;
}

async function beginArm(state, paths, sessionID, ctx, predecessorArmPid, generation) {
  if (!instanceIsActive(state, generation)) return { status: "inactive", armChild: null };
  if (!sessionID) return { status: "skipped", armChild: null };
  if (!(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
  if (!(await sessionOwnsLock(paths))) return { status: "read-only", armChild: null };
  if (state.child) return { status: "existing", armChild: state.child };
  if (state.retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
  // Every await above can outlive the instance that started this arm, so the
  // generation is rechecked here: a retired or superseded plugin instance must
  // not spawn a watcher that nobody will ever own.
  if (!instanceIsActive(state, generation)) return { status: "inactive", armChild: null };
  return { status: "spawned", armChild: spawnArm(state, paths, sessionID, ctx, predecessorArmPid, generation) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(state, paths, sessionID, ctx, predecessorArmPid, includeArmChild, generation) {
  if (!instanceIsActive(state, generation)) {
    return armAttempt("inactive", null, includeArmChild);
  }
  let launchResult = null;
  if (!state.launchInFlight) {
    const launch = beginArm(state, paths, sessionID, ctx, predecessorArmPid, generation);
    state.launchInFlight = launch;
    try {
      launchResult = await launch;
    } finally {
      if (state.launchInFlight === launch) state.launchInFlight = null;
    }
  } else {
    launchResult = await state.launchInFlight;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  return armAttempt(await waitForArmReady(state, armChild), armChild, includeArmChild);
}

function instanceIsActive(state, generation) {
  return generation !== null && generation === state.generation;
}

export default {
  id: "fm-primary-watch-arm",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    let state = instances.get(root);
    if (!state) {
      state = createInstance();
      instances.set(root, state);
    }
    state.generation += 1;
    const generation = state.generation;
    const paths = effectivePaths(root);
    // Keyed by root: OpenCode loads a plugin per location, so an unkeyed global
    // let a second firstmate checkout overwrite this one's coordinator and the
    // turn-end guard would then arm the wrong home.
    const coordinatorKey = watchArmCoordinatorKey(root);
    const coordinator = {
      ensureArmed: (sessionID, activeCtx) =>
        instanceIsActive(state, generation) ? ensureArm(state, paths, sessionID, activeCtx ?? ctx, "", false, generation) : "inactive",
    };
    globalThis[coordinatorKey] = coordinator;

    const stop = subscribeEvents(ctx, TURN_END_EVENTS, async (event) => {
      const sessionID = event.data?.sessionID;
      if (!sessionID || !instanceIsActive(state, generation)) return;
      void ensureArm(state, paths, sessionID, ctx, "", false, generation).catch(() => {
        // OpenCode owns arm failures; they surface as a failed watcher, not a dead plugin.
      });
    });

    // Unload must not leave an orphan arm child owning wake delivery for a home
    // this plugin instance no longer supervises, nor a coordinator the reloaded
    // instance would resolve to this retired one.
    return () => {
      stop();
      if (generation !== state.generation) return;
      // Deactivate first: anything already in flight now sees a retired
      // generation and cannot spawn a successor into an unloaded home.
      state.generation += 1;
      if (globalThis[coordinatorKey] === coordinator) {
        delete globalThis[coordinatorKey];
      }
      if (state.retryTimer) {
        clearTimeout(state.retryTimer);
        state.retryTimer = null;
        state.retryFailures = 0;
      }
      const retiring = state.child;
      state.child = null;
      if (retiring) void retireArm(state, retiring).catch(() => {});
    };
  },
};
