// Minimal OpenCode 2 plugin ctx double for firstmate's behavior tests.
//
// One owner for the seams the ported plugins touch:
//   ctx.location.directory  - replaces the V1 `directory` argument
//   ctx.event.subscribe      - async iterable of { type, data }, abortable
//   ctx.session.prompt       - V2 injection: ({ sessionID, text })
//   ctx.tool.hook            - "execute.before"; throwing blocks the call
//
// The event stream is one queue shared by every subscription, exactly as
// OpenCode's bus is. `emit` resolves only once every subscriber has pulled its
// next event, which can happen only after each handler for the emitted event
// has returned - so an assertion right after `await emit(...)` is
// deterministic, with no timer polling and no busy-wait. Emit one event at a
// time and await it before emitting the next.

export function makeOpenCodeCtx({ directory, onPrompt } = {}) {
  const queue = [];
  const waiters = [];
  const subscriptions = [];
  const toolHooks = new Map();
  const prompts = [];
  let aborted = false;

  const wake = () => {
    for (const waiter of waiters.splice(0)) waiter();
  };

  const ctx = {
    location: { directory },
    session: {
      prompt: async ({ sessionID, text }) => {
        prompts.push({ sessionID, text });
        if (onPrompt) await onPrompt({ sessionID, text });
        return {};
      },
    },
    event: {
      subscribe: ({ signal } = {}) => {
        const subscription = { pulls: 0 };
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
                  if (queue.length) return { done: false, value: queue.shift() };
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

  // Feed one { type, data } event; resolve once every subscriber has finished
  // handling it.
  const emit = async (type, data) => {
    const marks = subscriptions.map((subscription) => subscription.pulls);
    queue.push({ type, data });
    wake();
    for (;;) {
      if (aborted) return;
      if (queue.length) {
        await new Promise((resolve) => setImmediate(resolve));
        continue;
      }
      const settled = subscriptions.every(
        (subscription, index) => subscription.pulls > marks[index],
      );
      if (settled) return;
      await new Promise((resolve) => setImmediate(resolve));
    }
  };

  // Run a registered "execute.before" hook the way OpenCode does, reporting
  // whether it blocked the tool call and with what reason.
  const runToolHook = async (event) => {
    const fn = toolHooks.get("execute.before");
    if (!fn) return { blocked: false, reason: "" };
    try {
      await fn(event);
      return { blocked: false, reason: "" };
    } catch (error) {
      return { blocked: true, reason: String(error?.message ?? error) };
    }
  };

  return { ctx, emit, prompts, runToolHook, toolHooks };
}
