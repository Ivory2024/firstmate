// Minimal OpenCode 2 plugin ctx double for firstmate's behavior tests.
//
// One owner for the seams the ported plugins touch:
//   ctx.location.directory  - replaces the V1 `directory` argument
//   ctx.event.subscribe      - async iterable of { type, data }, abortable
//   ctx.session.prompt       - V2 injection: ({ sessionID, text })
//   ctx.tool.hook            - "execute.before"; throwing blocks the call
//
// Each event subscription receives its own copy, as on OpenCode's broadcast
// event bus. `emit` resolves only after every active subscriber has returned
// from handling that event, so assertions after `await emit(...)` are
// deterministic. Emit one event at a time and await it before emitting the next.

export function makeOpenCodeCtx({ directory, onPrompt } = {}) {
  const subscriptions = [];
  const toolHooks = new Map();
  const prompts = [];

  const wake = (subscription) => {
    for (const waiter of subscription.waiters.splice(0)) waiter();
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
        const subscription = { pulls: 0, queue: [], waiters: [], aborted: false };
        subscriptions.push(subscription);
        if (signal) {
          if (signal.aborted) subscription.aborted = true;
          else signal.addEventListener("abort", () => {
            subscription.aborted = true;
            wake(subscription);
          }, { once: true });
        }
        return {
          [Symbol.asyncIterator]() {
            return {
              async next() {
                subscription.pulls += 1;
                for (;;) {
                  if (subscription.queue.length) return { done: false, value: subscription.queue.shift() };
                  if (subscription.aborted) return { done: true, value: undefined };
                  await new Promise((resolve) => subscription.waiters.push(resolve));
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
    for (const subscription of subscriptions) {
      if (subscription.aborted) continue;
      subscription.queue.push({ type, data });
      wake(subscription);
    }
    for (;;) {
      const settled = subscriptions.every((subscription, index) =>
        subscription.aborted || (
          subscription.pulls > marks[index] && subscription.queue.length === 0
        ),
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
