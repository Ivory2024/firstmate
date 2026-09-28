import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { subscribeEvents, TURN_END_EVENTS, watchArmCoordinatorKey } from "./lib/fm-opencode-events.js";

// Per session, not per module: OpenCode 2 loads this plugin once per location and
// serves every session in it, so one shared flag would let one session's injected
// recovery prompt suppress another session's turn-end check.
const skipNextTurnEnd = new Set();

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

async function letWatchArmRun(sessionID, ctx, root) {
  // Keyed by this guard's own root, so it can only ever ask the arm coordinator
  // for the home it actually supervises.
  const coordinator = globalThis[watchArmCoordinatorKey(root)];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, ctx);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);

    return subscribeEvents(ctx, TURN_END_EVENTS, async (event) => {
      const sessionID = event.data?.sessionID;
      if (!sessionID) return;

      // Suppress exactly the turn end caused by this guard's own injected
      // recovery prompt, and only for the session that received it.
      if (skipNextTurnEnd.delete(sessionID)) return;

      if (await letWatchArmRun(sessionID, ctx, root)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await ctx.session.prompt({ sessionID, text });
        skipNextTurnEnd.add(sessionID);
      } catch {
        skipNextTurnEnd.delete(sessionID);
      }
    });
  },
};
