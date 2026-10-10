import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode 2.0.18: block a stray persistent top-level
// `cd` in the primary firstmate checkout before the agent's bash tool relocates
// the shell out of the home (see bin/fm-cd-pretool-check.sh and docs/cd-guard.md).
// The owner script is itself inert outside the real primary checkout, so a
// crewmate/scout worktree is never affected.
//
// OpenCode 2 plugin shape: `export default { id, setup(ctx) }`. The 1.x ctx
// fields are gone: the working directory is `ctx.location.directory`, and the
// old `tool.execute.before` hook is `ctx.tool.hook("execute.before", handler)`.
// `ctx.worktree` is an object, not a path, so the repo root is resolved from
// ctx.location.directory.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export default {
  id: "fm-primary-cd-check",
  setup(ctx) {
    let rootPromise = null;
    const root = () => (rootPromise ??= resolveRoot(ctx.location?.directory));

    ctx.tool.hook("execute.before", async (arg) => {
      const r = await root();
      if (!r || arg?.tool !== "bash") return;
      const command = arg?.input?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${r}/bin/fm-cd-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt";
      throw new Error(reason);
    });

    return () => {};
  },
};
