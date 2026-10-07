#!/usr/bin/env bash
# Regression test for the OpenCode v2 plugin entrypoint and hook registration contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out=$(node --input-type=module - "$ROOT" 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const plugins = [
  ["fm-primary-cd-check.js", "fm-primary-cd-check", "tool"],
  ["fm-primary-pretool-check.js", "fm-primary-pretool-check", "tool"],
  ["fm-primary-sessionstart-nudge.js", "fm-primary-sessionstart-nudge", "event"],
  ["fm-primary-turnend-guard.js", "fm-primary-turnend-guard", "event"],
  ["fm-primary-watch-arm.js", "fm-primary-watch-arm", "event"],
];

for (const [filename, id, domain] of plugins) {
  const moduleUrl = pathToFileURL(`${root}/.opencode/plugins/${filename}`);
  const plugin = (await import(moduleUrl.href)).default;
  assert.equal(typeof plugin?.id, "string", `${filename} has a default id`);
  assert.equal(plugin.id, id, `${filename} exports its stable plugin id`);
  assert.equal(typeof plugin?.setup, "function", `${filename} has a v2 setup function`);

  const registrations = [];
  let eventDrained = false;
  const ctx = {
    location: { directory: "" },
    session: { prompt: async () => {} },
    tool: {
      hook: async (name, callback) => registrations.push({ domain: "tool", name, callback }),
    },
    event: {
      subscribe: ({ signal } = {}) => (async function* () {
        if (!signal?.aborted) eventDrained = true;
      })(),
    },
  };

  const cleanup = await plugin.setup(ctx);
  if (domain === "tool") {
    assert.deepEqual(registrations.map(({ name }) => name), ["execute.before"], `${filename} registers its v2 tool hook`);
  } else {
    for (let i = 0; i < 50 && !eventDrained; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(eventDrained, true, `${filename} subscribes through the v2 event domain`);
  }
  await cleanup?.();
}
EOF
) || fail "OpenCode plugins failed the v2 default-export/setup contract: $out"
[ -z "$out" ] || fail "OpenCode v2 plugin contract test printed output: $out"
pass "all five OpenCode plugins export v2 id/setup definitions and register through ctx domains"
