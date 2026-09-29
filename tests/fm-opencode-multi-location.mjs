import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const { makeOpenCodeCtx } = await import(pathToFileURL(process.env.CTX_LIB).href);
const { watchArmCoordinatorKey } = await import(pathToFileURL(process.env.EVENTS_LIB).href);
for (const root of [process.env.ROOT_A, process.env.ROOT_B]) {
  mkdirSync(`${root}/bin`, { recursive: true });
  mkdirSync(`${root}/state`, { recursive: true });
  writeFileSync(`${root}/AGENTS.md`, "");
  writeFileSync(`${root}/state/task.meta`, "");
  const git = spawnSync("git", ["init", "-q", root], { encoding: "utf8" });
  if (git.status !== 0) throw new Error(git.stderr || "git init failed");
  writeFileSync(`${root}/bin/fm-watch-arm.sh`, `#!/usr/bin/env bash
printf 'started pid=%s\\n' "$$" >> "$PWD/watch.log"
printf 'watcher: started pid=%s (beacon fresh)\\n' "$$"
exec sleep 30
`);
  chmodSync(`${root}/bin/fm-watch-arm.sh`, 0o755);
}
const a = makeOpenCodeCtx({ directory: process.env.ROOT_A });
const b = makeOpenCodeCtx({ directory: process.env.ROOT_B });
const disposeA = await mod.default.setup(a.ctx);
const disposeB = await mod.default.setup(b.ctx);
writeFileSync(`${process.env.ROOT_A}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.ROOT_B}/state/.lock`, `${process.pid}\n`);
await Promise.all([
  a.emit("session.execution.succeeded", { sessionID: "a" }),
  b.emit("session.execution.succeeded", { sessionID: "b" }),
]);
for (let i = 0; i < 250 && (!existsSync(process.env.LOG_A) || !existsSync(process.env.LOG_B)); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.LOG_A) || !existsSync(process.env.LOG_B)) {
  throw new Error("both Firstmate locations must start their watcher");
}
disposeA();
await b.emit("session.execution.succeeded", { sessionID: "b" });
const coordinatorB = globalThis[watchArmCoordinatorKey(process.env.ROOT_B)];
const statusB = await coordinatorB.ensureArmed("b", b.ctx);
if (statusB !== "armed") throw new Error(`second location did not remain armed after first cleanup: ${statusB}`);
disposeB();
