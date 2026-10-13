import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { OpenCodeLifecycleAdapter, QUIESCENT } from "./lib/fm-opencode-lifecycle-adapter.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

// One skip per session: the follow-up turn this plugin forces must not re-block
// itself on its own terminal event, and a second session on the same server must
// not have its guard run swallowed by the first session's follow-up.
const skipSessions = new Set();

// v2.0.27 emits no `session.idle` (verified live 2026-10-13): the turn boundary
// is `session.execution.succeeded|failed|interrupted`. Normalize those terminals
// to QUIESCENT exactly like fm-primary-watch-arm.js, and keep legacy
// `session.idle` for pre-v2 runtimes.
const lifecycle = new OpenCodeLifecycleAdapter();

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

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event, signal }) => {
      // setup() always passes the normalized signal; a direct caller (legacy
      // unit path) may pass only the event, so derive the signal from it.
      const effective = signal ?? lifecycle.normalize(event);
      if (!effective) return;
      const isIdle = event.type === "session.idle";
      const isQuiescent = effective.type === QUIESCENT;
      if (!isIdle && !isQuiescent) return;

      const sessionID = isIdle ? event.properties?.sessionID : effective.sessionID;
      if (!sessionID) return;

      if (skipSessions.has(sessionID)) {
        skipSessions.delete(sessionID);
        return;
      }

      if (await letWatchArmRun(sessionID, client)) return;

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
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipSessions.add(sessionID);
      } catch {
        skipSessions.delete(sessionID);
      }
    },
  };
};

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const client = {
      session: {
        promptAsync: ({ path, body }) => ctx.session.prompt({
          sessionID: path.id,
          text: body.parts.map((part) => part.text ?? "").join(""),
        }),
      },
    };
    const hooks = await FmPrimaryTurnendGuard({
      client,
      directory: ctx.location?.directory,
      worktree: ctx.location?.worktree,
    });
    const controller = new AbortController();
    const eventTask = (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        await hooks.event({ event: { ...event, properties: event.data }, signal: lifecycle.normalize(event) });
      }
    })().catch(() => {});
    return async () => {
      controller.abort();
      await eventTask;
    };
  },
};
