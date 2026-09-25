import assert from 'node:assert/strict';
import { createHmac, randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import test, { after } from 'node:test';
import { join } from 'node:path';
import { register } from '../.claude/jev-marketplace/jev-safe/hooks/jev.ts';
import { applyDecisions } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/compact.ts';
import { fitState } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/state.ts';

const safetyRoot = await mkdtemp(join(process.cwd(), '.jev-hook-gate-test-'));
const safetyKey = randomBytes(32).toString('hex');
await mkdir(join(safetyRoot, '.claude/jev-safety'), { recursive: true });
await writeFile(join(safetyRoot, '.claude/jev-safety/.gate-key'), safetyKey, { mode: 0o600 });
after(async () => rm(safetyRoot, { recursive: true, force: true }));

function safetyProof(url) {
  const nonce = new URL(url).searchParams.get('nonce');
  return JSON.stringify({ nonce, proof: createHmac('sha256', safetyKey).update(nonce).digest('hex') });
}

function fixtureMessages() {
  return [
    { role: 'user', text: 'Compact this synthetic fixture history.', toolUses: [] },
    {
      role: 'assistant',
      text: '',
      toolUses: [{ tool_use_id: 'fixture-read', tool: 'Read', input: { file_path: 'synthetic-fixture.txt' } }],
    },
    {
      role: 'user',
      text: '',
      toolUses: [],
      toolResults: [{ tool_use_id: 'fixture-read', text: 'Synthetic fixture output.\n'.repeat(100) }],
    },
  ];
}

function hooks() {
  const registered = [];
  register((...args) => registered.push(args), { preserveRecentMessages: 0, minReductionRatio: 0 });
  return registered;
}

function ui() {
  return { log() {}, toast() {} };
}

test('fast-jev falls back without a key and sends no request', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  let fallback = false;
  let requests = 0;
  await handler({
    http: { async fetch() { requests += 1; throw new Error('unexpected request'); } },
    env: { async get() { return undefined; } },
    settings: { async read() { return {}; } },
    session: { async cwd() { return safetyRoot; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests, 0);
});

test('fast-jev preserves conversation text and configured goals in state', () => {
  const state = fitState([
    { role: 'user', text: 'task-message-fixture-unique', toolUses: [] },
  ], [], { maxStateTokens: 1000, preserveRecentMessages: 0, goal: 'task-goal-fixture-unique' });
  assert.equal(state.state.goal, 'task-goal-fixture-unique');
  assert.equal(state.state.history[0]?.text, 'task-message-fixture-unique');
});

test('fast-jev omits dropped results whole and preserves kept results verbatim', () => {
  const retainedText = 'retained result, unchanged';
  const droppedText = 'leading payload\nprivate trailing payload';
  const retainedResult = { tool_use_id: 'retained', text: retainedText };
  const messages = [
    {
      role: 'assistant',
      text: '',
      toolUses: [
        { tool_use_id: 'retained', tool: 'Read', input: {}, text: retainedText },
        { tool_use_id: 'dropped', tool: 'Read', input: {}, text: droppedText },
      ],
    },
    {
      role: 'user',
      text: '',
      toolUses: [],
      toolResults: [
        retainedResult,
        { tool_use_id: 'dropped', text: droppedText },
      ],
    },
  ];
  const output = applyDecisions(messages, [
    { id: 't2', tool: 'Read', keepCall: 1, keepResult: 0, action: 'drop_result', reason: 'result_dropped' },
  ], [
    { id: 't2', tool_use_id: 'dropped', tool: 'Read', input: {}, callIndex: 0, resultIndex: 1, resultChars: droppedText.length, isError: false, pinned: false },
  ]);
  assert.equal(output[0]?.toolUses[0]?.text, retainedText);
  assert.equal(output[0]?.toolUses[1]?.text, '[omitted: result_dropped]');
  assert.equal(output[1]?.toolResults?.[0], retainedResult);
  assert.equal(output[1]?.toolResults?.[1]?.text, '[omitted: result_dropped]');
  assert.equal(JSON.stringify(output).includes('leading payload'), false);
  assert.equal(JSON.stringify(output).includes('private trailing payload'), false);
});

test('fast-jev uses its default after a mocked invalid-key response', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) {
      requests.push(url);
      if (url.includes('/health?nonce=')) {
        return { status: 200, ok: true, text: safetyProof(url) };
      }
      return url.endsWith('/check')
        ? { status: 200, ok: true, text: '{"allowed":true,"reason":"clean"}' }
        : { status: 401, ok: false, text: 'unauthorized' };
    } },
    env: { async get() { return 'invalid-test-key'; } },
    settings: { async read() { return {}; } },
    session: { async cwd() { return safetyRoot; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 3);
  assert.match(requests[0], /127\.0\.0\.1:48752\/health\?nonce=[a-f0-9]{64}$/);
  assert.match(requests[1], /127\.0\.0\.1:48752\/check$/);
});

test('fast-jev falls back to the authorized .env key after env and settings', async () => {
  const root = await mkdtemp(join(process.cwd(), '.fast-jev-key-test-'));
  try {
    await writeFile(join(root, '.env'), 'export TYPESAFE_API_KEY="synthetic-fast-jev-key"\n');
    const entry = hooks().find(([event]) => event === 'session.compact');
    const handler = entry.at(-1);
    const requests = [];
    await handler({
      http: { async fetch(url, init) {
        requests.push({ url, init });
        if (url.includes('/health?nonce=')) {
          return { status: 200, ok: true, text: safetyProof(url) };
        }
        if (url.endsWith('/check')) return { status: 200, ok: true, text: '{"allowed":true}' };
        return { status: 401, ok: false, text: 'unauthorized' };
      } },
      env: { async get(name) { return name === 'FM_HOME' ? root : undefined; } },
      settings: { async read() { return {}; } },
      session: { async cwd() { return safetyRoot; } },
      ui: ui(),
    }, { messages: fixtureMessages() }, async () => 'default');
    const jevRequest = requests.find(({ url }) => url.startsWith('https://api.typesafe.ai/'));
    assert.equal(jevRequest?.init?.headers?.authorization, 'Bearer synthetic-fast-jev-key');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('fast-jev rejects a spoofed static safety identity before posting the payload', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) {
      requests.push(url);
      return { status: 200, ok: true, text: '{"service":"firstmate-jev-safety","protocol":1}' };
    } },
    env: { async get() { return 'synthetic-key'; } },
    settings: { async read() { return {}; } },
    session: { async cwd() { return safetyRoot; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /127\.0\.0\.1:48752\/health\?nonce=[a-f0-9]{64}$/);
});

test('winnow preserves the original result when the safety gate blocks its path', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'synthetic result.\n'.repeat(200) } };
  const requests = [];
  const event = { tool: 'Read', tool_use_id: 'fixture', file_path: 'data/captain.md' };
  const returned = await handler({
    http: { async fetch(url) {
      requests.push(url);
      if (url.includes('/health?nonce=')) {
        return { status: 200, ok: true, text: safetyProof(url) };
      }
      return { status: 200, ok: true, text: '{"allowed":false,"reason":"sensitive_path"}' };
    } },
    session: {
      async messages() {
        return [
          { role: 'user', text: 'Find the captain preferences.' },
          { role: 'assistant', text: 'I will read the requested file.' },
        ];
      },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, event, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 2);
  assert.match(requests[0], /127\.0\.0\.1:48752\/health\?nonce=[a-f0-9]{64}$/);
  assert.match(requests[1], /127\.0\.0\.1:48752\/check$/);
});

test('winnow sends live user and assistant context after the safety gate allows it', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'result block.\n'.repeat(200) } };
  const requests = [];
  const messages = [
    { role: 'user', text: 'Find the relevant runtime setting.' },
    { role: 'assistant', text: 'I will inspect the configuration docs.' },
  ];
  await handler({
    http: { async fetch(url, init) {
      requests.push({ url, body: init?.body });
      if (url.includes('/health?nonce=')) {
        return { status: 200, ok: true, text: safetyProof(url) };
      }
      return url.endsWith('/check')
        ? { status: 200, ok: true, text: '{"allowed":true}' }
        : { status: 200, ok: true, text: '{"hookSpecificOutput":{}}', headers: {} };
    } },
    session: {
      async messages() { return messages; },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/configuration.md' }, async () => answer);
  assert.equal(requests.length, 3);
  assert.match(requests[0].url, /127\.0\.0\.1:48752\/health\?nonce=[a-f0-9]{64}$/);
  assert.match(requests[1].url, /127\.0\.0\.1:48752\/check$/);
  assert.match(requests[2].url, /127\.0\.0\.1:47311\/hook\/post-tool-use$/);
  assert.deepEqual(JSON.parse(requests[2].body).task, {
    user_request: 'Find the relevant runtime setting.',
    assistant_intent: 'I will inspect the configuration docs.',
  });
});

test('winnow rejects a spoofed static safety identity before posting to the sidecar', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'result block.\n'.repeat(200) } };
  const requests = [];
  const returned = await handler({
    http: { async fetch(url) {
      requests.push(url);
      return { status: 200, ok: true, text: '{"service":"firstmate-jev-safety","protocol":1}' };
    } },
    session: {
      async messages() { return [
        { role: 'user', text: 'Find a setting.' },
        { role: 'assistant', text: 'I will inspect the docs.' },
      ]; },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/guide.md' }, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /127\.0\.0\.1:48752\/health\?nonce=[a-f0-9]{64}$/);
});

test('winnow does not register prompt submission transmission', () => {
  assert.equal(hooks().some(([event]) => event === 'prompt.submit'), false);
});
