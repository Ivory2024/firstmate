import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own bash tool - the anti-pattern bin/fm-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).
// OpenCode 2's ctx.tool.hook("execute.before") blocks by throwing, the same
// mechanism the V1 tool.execute.before hook used (verified on 1.17.15, and
// re-verified against the V2 hook on 2.0.18).

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
    const root = await resolveRoot(ctx.location?.directory);
    if (!root) return;

    await ctx.tool.hook("execute.before", async (event) => {
      // OpenCode 2 reports the bash tool's internal id as "shell" (verified
      // 2.0.18); "bash" is kept so this seatbelt can never fail open if the id
      // differs again. Throwing blocks the call - verified 2.0.18.
      if (event?.tool !== "shell" && event?.tool !== "bash") return;
      const command = event.input?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    });
  },
};
