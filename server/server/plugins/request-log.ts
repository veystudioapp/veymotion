import { definePlugin } from "nitro";

export default definePlugin((nitroApp) => {
  nitroApp.hooks.hook("request", (event) => {
    event.context.requestStart = performance.now();
  });

  nitroApp.hooks.hook("response", (res, event) => {
    const start = event.context.requestStart as number | undefined;
    const duration = start === undefined ? 0 : performance.now() - start;
    console.log(
      `${event.req.method} ${event.url.pathname} ${res.status} ${duration.toFixed(1)}ms`
    );
  });

  nitroApp.hooks.hook("error", (error, { event }) => {
    console.error(`${event?.req.method} ${event?.url.pathname} failed:`, error);
  });
});
