import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
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
  const info = event.data?.info ?? event.properties?.info;
  const observedDirectories = [event.location?.directory, info?.directory].filter(Boolean);
  if (observedDirectories.length) {
    return observedDirectories.every((path) => resolvePath(path) === directory);
  }
  if (!sessionID || !getSession) return false;
  try {
    const session = await getSession(sessionID);
    return resolvePath(session?.directory) === directory;
  } catch {
    return false;
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree, isOwnSession }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const handledSessions = new Set();

  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.data?.sessionID ?? event.data?.info?.id ?? event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      if (!await isOwnSession?.(event, sessionID)) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: nudge }],
          },
        });
      } catch {
      }
    },
  };
};

export default {
  id: "fm-primary-sessionstart-nudge",
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
    const hooks = await FmPrimarySessionstartNudge({
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
        await hooks.event({ event });
      }
    })().catch(() => {});
    return async () => {
      controller.abort();
      await eventTask;
    };
  },
};
