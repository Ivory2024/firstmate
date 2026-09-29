import { chmodSync, existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

writeFileSync(`${process.env.WORKTREE}/bin/fm-watch-arm.sh`, `#!/usr/bin/env bash
printf 'arm\\n' >> "\${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\\n'
`);
writeFileSync(`${process.env.WORKTREE}/bin/fm-turnend-guard.sh`, `#!/usr/bin/env bash
printf 'guard\\n' >> "\${FM_GUARD_LOG:?}"
printf 'guard should not run\\n' >&2
exit 2
`);
chmodSync(`${process.env.WORKTREE}/bin/fm-watch-arm.sh`, 0o755);
chmodSync(`${process.env.WORKTREE}/bin/fm-turnend-guard.sh`, 0o755);
const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
const { makeOpenCodeCtx } = await import(pathToFileURL(process.env.CTX_LIB).href);
let promptBody = "";
const { ctx, emit } = makeOpenCodeCtx({
  directory: process.env.WORKTREE,
  onPrompt: async ({ text }) => {
    promptBody = text;
  },
});
const disposeArm = await armMod.default.setup(ctx);
const disposeGuard = await guardMod.default.setup(ctx);
try {
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
  await emit("session.execution.succeeded", { sessionID: "session-test" });
  for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("watch arm did not run");
  if (existsSync(process.env.FM_GUARD_LOG)) throw new Error("turn-end guard ran before arm setup");
  if (promptBody) throw new Error(`unexpected prompt: ${promptBody}`);
} finally {
  disposeGuard();
  disposeArm();
}
