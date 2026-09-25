import assert from 'node:assert/strict';
import test from 'node:test';
import { register } from '../.claude/jev-marketplace/jev-safe/hooks/jev.ts';
import { fitState } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/state.ts';

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

test('fast-jev uses its default after a mocked invalid-key response', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) {
      requests.push(url);
      return url.endsWith('/check')
        ? { status: 200, ok: true, text: '{"allowed":true,"reason":"clean"}' }
        : { status: 401, ok: false, text: 'unauthorized' };
    } },
    env: { async get() { return 'invalid-test-key'; } },
    settings: { async read() { return {}; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 2);
  assert.match(requests[0], /127\.0\.0\.1:48752\/check$/);
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
      async cwd() { return '/synthetic'; },
    },
    ui: ui(),
  }, event, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /127\.0\.0\.1:48752\/check$/);
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
      return url.endsWith('/check')
        ? { status: 200, ok: true, text: '{"allowed":true}' }
        : { status: 200, ok: true, text: '{"hookSpecificOutput":{}}', headers: {} };
    } },
    session: {
      async messages() { return messages; },
      async id() { return 'synthetic'; },
      async cwd() { return '/synthetic'; },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/configuration.md' }, async () => answer);
  assert.equal(requests.length, 2);
  assert.match(requests[0].url, /127\.0\.0\.1:48752\/check$/);
  assert.match(requests[1].url, /127\.0\.0\.1:47311\/hook\/post-tool-use$/);
  assert.deepEqual(JSON.parse(requests[1].body).task, {
    user_request: 'Find the relevant runtime setting.',
    assistant_intent: 'I will inspect the configuration docs.',
  });
});

test('winnow does not register prompt submission transmission', () => {
  assert.equal(hooks().some(([event]) => event === 'prompt.submit'), false);
});
