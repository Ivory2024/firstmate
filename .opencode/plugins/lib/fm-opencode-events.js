// Cross-plugin adapter for OpenCode 2.x, which dropped the V1 `event` hook in
// favour of a subscription to the public event stream. One owner for the
// subscription boilerplate, the turn-end event set, and the key the arm plugin
// publishes its coordinator under, so the arm coordinator and the turn-end
// guard cannot drift apart on any of them.
// bin/fm-operational-input.sh still owns the marker protocol itself.

export const TURN_END_EVENTS = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
];

// OpenCode 2 loads a plugin once per location, so two loaded firstmate checkouts
// share one process. The key is scoped by root: without it the second location's
// setup overwrites the first's coordinator and the turn-end guard would arm the
// wrong home.
export function watchArmCoordinatorKey(root) {
  return `__firstmateOpenCodeWatchArm:${root}`;
}

// OpenCode 2 events arrive as { type, data }. `handler` runs serially, one
// event at a time, so an awaited handler cannot interleave with the next
// event; a throwing handler is contained so the stream survives it.
// Returns the cleanup function OpenCode calls when the plugin unloads.
export function subscribeEvents(ctx, types, handler) {
  const wanted = new Set(types);
  const controller = new AbortController();
  void (async () => {
    try {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (!wanted.has(event?.type)) continue;
        try {
          await handler(event);
        } catch {
        }
      }
    } catch {
    }
  })();
  return () => controller.abort();
}
