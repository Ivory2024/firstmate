import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { QUIESCENT_EVENTS } from "./lib/fm-opencode-events.js";

// OpenCode 2.0.18 turn-end guard. Shape: `export default { id, setup(ctx) }`.
// The 1.x ctx fields are gone: working dir is `ctx.location.directory`, the old
// `event` hook is a `ctx.event.subscribe({ signal })` stream, and
// `client.session.promptAsync` is `ctx.session.prompt`. The watch-arm coordinator
// is still shared through globalThis so this guard defers to a live arm.

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
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

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(directory, sessionID) {
  const coordinator = globalThis[COORDINATOR_KEY]?.get(directory);
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "fm-primary-turnend-guard",
  setup(ctx) {
    const directory = ctx.location?.directory;
    let rootPromise = null;
    const root = () => (rootPromise ??= resolveRoot(ctx.location?.directory));
    const controller = new AbortController();
    let skipNextIdle = false;

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (event?.location?.directory !== ctx.location?.directory) continue;
          if (!QUIESCENT_EVENTS.has(event?.type)) continue;

          if (skipNextIdle) {
            skipNextIdle = false;
            continue;
          }

          const sessionID = event.data?.sessionID ?? event.properties?.sessionID;
          if (!sessionID) continue;

          if (await letWatchArmRun(directory, sessionID)) continue;

          const r = await root();
          const result = await runGuard(r);
          if (result.code !== 2) continue;

          try {
            const text = await encodeFirstmateOperationalInput(
              r,
              "turn-end-guard",
              "TURN WOULD END BLIND - supervision is off. " +
                "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
                result.stderr,
            );
            await ctx.session.prompt({ sessionID, text });
            skipNextIdle = true;
          } catch {
            skipNextIdle = false;
          }
        }
      } catch {
      }
    })();

    return () => controller.abort();
  },
};
