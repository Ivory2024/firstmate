import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode 2.0.18: the arm mechanism itself lives
// entirely in fm-primary-watch-arm.js (a plugin-owned child process, never a
// model tool call), so the residual risk here is the AGENT shelling
// `bin/fm-watch-arm.sh` wrong through its own bash tool - the anti-pattern
// bin/fm-arm-pretool-check.sh guards against (see that script's header and
// docs/arm-pretool-check.md).
//
// OpenCode 2 plugin shape: `export default { id, setup(ctx) }`; working dir is
// `ctx.location.directory`; the old `tool.execute.before` is
// `ctx.tool.hook("execute.before", handler)`.

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
  id: "fm-primary-pretool-check",
  async setup(ctx) {
    let rootPromise = null;
    const root = () => (rootPromise ??= resolveRoot(ctx.location?.directory));

    const registration = await ctx.tool.hook("execute.before", async (arg) => {
      const r = await root();
      if (!r || arg?.tool !== "bash") return;
      const command = arg?.input?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${r}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    });

    return () => registration.dispose();
  },
};
