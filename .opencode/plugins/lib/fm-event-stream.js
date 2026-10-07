function waitForRetry(delay, signal) {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, delay);
    timer.unref?.();
    signal.addEventListener("abort", finish, { once: true });
  });
}

function retryDelay(attempt) {
  return Math.min(30000, 250 * 2 ** Math.min(attempt - 1, 7));
}

export async function consumeEventStream({ subscribe, signal, onEvent, onFailure }) {
  let attempt = 0;
  let failureReported = false;

  while (!signal.aborted) {
    try {
      for await (const event of subscribe({ signal })) {
        if (signal.aborted) return;
        attempt = 0;
        failureReported = false;
        await onEvent(event);
      }
      if (signal.aborted) return;
      throw new Error("event stream ended unexpectedly");
    } catch (error) {
      if (signal.aborted) return;
      attempt += 1;
      const delay = retryDelay(attempt);
      if (!failureReported) {
        failureReported = true;
        onFailure?.(error, { attempt, delay });
      }
      await waitForRetry(delay, signal);
    }
  }
}
