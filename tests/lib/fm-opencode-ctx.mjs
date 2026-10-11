// Minimal OpenCode 2 plugin ctx double for firstmate's behavior tests.
//
// One owner for the seams the ported plugins touch:
//   ctx.location.directory  - replaces the V1 `directory` argument
//   ctx.event.subscribe      - async iterable of { type, data }, abortable
//   ctx.session.prompt       - V2 injection: ({ sessionID, text })
//   ctx.tool.hook            - "execute.before"; throwing blocks the call
//
// Two details of the real bus are reproduced, because a test that gets either
// wrong passes or hangs for the wrong reason:
//
//   Broadcast. Every subscriber sees every event in order, so the log is shared
//   and each subscription carries its own read cursor instead of competing for
//   one queue.
//
//   Handler completion. The plugin's consume loop awaits its handler before
//   pulling the next event, so a subscriber's NEXT call into next() happens only
//   after its handler has returned. Counting those calls is therefore an exact
//   "this handler finished" signal, and `emit` can resolve deterministically with
//   no timer polling and no busy-wait.
//
// Emit one event at a time and await it before emitting the next.

export function makeOpenCodeCtx({ directory, onPrompt, client } = {}) {
  const log = [];
  const waiters = [];
  const subscriptions = [];
  const toolHooks = new Map();
  const prompts = [];
  let aborted = false;

  const wake = () => {
    for (const waiter of waiters.splice(0)) waiter();
  };

  const recordPrompt = async ({ sessionID, text }) => {
    prompts.push({ sessionID, text });
    if (onPrompt) await onPrompt({ sessionID, text });
    // A case that still records through the V1 `session.promptAsync({ path,
    // body })` envelope keeps its own recorder: the V2 call is forwarded into
    // that envelope so the case's body and assertions stay byte-identical.
    if (client?.session?.promptAsync) {
      await client.session.promptAsync({ path: { id: sessionID }, body: { parts: [{ type: "text", text }] } });
    }
    return {};
  };

  const ctx = {
    location: { directory },
    session: {
      prompt: recordPrompt,
    },
    event: {
      subscribe: ({ signal } = {}) => {
        // `cursor` counts delivered events; `pulls` counts calls into next().
        const subscription = { cursor: 0, pulls: 0 };
        subscriptions.push(subscription);
        if (signal) {
          if (signal.aborted) aborted = true;
          else signal.addEventListener("abort", () => { aborted = true; wake(); });
        }
        return {
          [Symbol.asyncIterator]() {
            return {
              async next() {
                subscription.pulls += 1;
                for (;;) {
                  if (subscription.cursor < log.length) {
                    const value = log[subscription.cursor];
                    subscription.cursor += 1;
                    return { done: false, value };
                  }
                  if (aborted) return { done: true, value: undefined };
                  await new Promise((resolve) => waiters.push(resolve));
                }
              },
            };
          },
        };
      },
    },
    tool: {
      hook: async (name, fn) => {
        toolHooks.set(name, fn);
        return { dispose() { toolHooks.delete(name); } };
      },
    },
  };

  // Broadcast one { type, data } event; resolve once every subscriber has both
  // taken delivery of it and finished handling it.
  const emit = async (type, data) => {
    const marks = subscriptions.map((subscription) => ({
      cursor: subscription.cursor,
      pulls: subscription.pulls,
    }));
    log.push({ type, data });
    wake();
    for (;;) {
      if (aborted) return;
      const settled = subscriptions.every((subscription, index) => (
        subscription.cursor > marks[index].cursor
        && subscription.pulls > marks[index].pulls
      ));
      if (settled) return;
      await new Promise((resolve) => setImmediate(resolve));
    }
  };

  // The V2 injection handle the plugin's internal `client` shim wraps, so a
  // case that passes an explicit client to a coordinator call keeps working.
  const promptClient = { session: { promptAsync: (args) => ctx.session.prompt(args) } };

  return { ctx, emit, prompts, toolHooks, promptClient };
}

// A drive handle for cases written against the V1 `{ event }` shape: each call
// is forwarded into the V2 subscribe stream, so the case keeps its own body.
export function eventHandle(emit) {
  return { event: ({ event }) => emit(event?.type, event?.properties ?? event?.data) };
}
