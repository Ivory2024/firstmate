import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// OpenCode 2.0.18 session-start nudge. Shape: `export default { id, setup(ctx) }`.
// The 1.x ctx fields are gone: working dir is `ctx.location.directory`, the old
// `event` hook is a `ctx.event.subscribe({ signal })` stream, and
// `client.session.promptAsync` is `ctx.session.prompt`.

const handledSessions = new Set();

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
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export default {
  id: "fm-primary-sessionstart-nudge",
  setup(ctx) {
    let rootPromise = null;
    const root = () => (rootPromise ??= resolveRoot(ctx.location?.directory));
    const controller = new AbortController();

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          // OpenCode 2.0.18 has no `session.created`; the session-start signal is
          // `session.instructions.updated` (fires once at session start).
          if (event?.type !== "session.instructions.updated") continue;
          const sessionID = event.data?.sessionID ?? event.data?.info?.id ?? event.properties?.info?.id ?? event.properties?.sessionID;
          if (!sessionID || handledSessions.has(sessionID)) continue;
          const r = await root();
          if (!r) continue;
          handledSessions.add(sessionID);

          const result = await runProcess(`${r}/bin/fm-sessionstart-nudge.sh`, []);
          const nudge = result.code === 0 ? result.stdout.trim() : "";
          if (!nudge) continue;

          try {
            await ctx.session.prompt({ sessionID, text: nudge });
          } catch {
          }
        }
      } catch {
      }
    })();

    return () => controller.abort();
  },
};
