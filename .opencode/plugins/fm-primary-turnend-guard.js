import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

function watchArmCoordinatorKey(root) {
  return `__firstmateOpenCodeWatchArm:${root}`;
}

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
  if (!anchor) return "";
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function isSessionInLoadedDirectory(event, sessionID, directory, getSession) {
  if (!directory) return false;
  const observedDirectory = event.location?.directory ?? event.data?.info?.directory ?? event.properties?.info?.directory;
  if (observedDirectory) return resolvePath(observedDirectory) === directory;
  if (!sessionID || !getSession) return false;
  try {
    const session = await getSession(sessionID);
    return resolvePath(session?.directory) === directory;
  } catch {
    return false;
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(sessionID, client, root) {
  const coordinator = globalThis[watchArmCoordinatorKey(root)];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree, isOwnSession }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  let skipNextIdle = false;

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      const sessionID = event.data?.sessionID ?? event.properties?.sessionID;
      if (!sessionID) return;
      if (!await isOwnSession?.(event, sessionID)) return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      if (await letWatchArmRun(sessionID, client, root)) return;

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
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const loadedDirectory = resolvePath(ctx.location?.worktree ?? ctx.location?.directory);
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
      isOwnSession: (event, sessionID) => isSessionInLoadedDirectory(
        event,
        sessionID,
        loadedDirectory,
        (id) => ctx.session.get({ sessionID: id }),
      ),
    });
    const controller = new AbortController();
    const eventTask = (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (!isTurnEndEvent(event?.type)) continue;
        const sessionID = event.data?.sessionID ?? event.data?.info?.id ?? event.properties?.sessionID ?? event.properties?.info?.id;
        if (!sessionID) continue;
        await hooks.event({ event: { ...event, type: "session.idle", data: { ...event.data, sessionID } } });
      }
    })().catch(() => {});
    return async () => {
      controller.abort();
      await eventTask;
    };
  },
};

function isTurnEndEvent(type) {
  return type === "session.idle" || type === "session.execution.succeeded" ||
    type === "session.execution.failed" || type === "session.execution.interrupted";
}
