import * as Sentry from "@sentry/node";

/**
 * Crash and error reports to Sentry, only when SENTRY_DSN is set (Render > doorlist-server >
 * Environment). Imported first in index.ts so it starts before anything else loads.
 * No request bodies or personal details: answers, emails and voice never leave in a report.
 */
export const sentryOn = Boolean(process.env.SENTRY_DSN) && process.env.NODE_ENV !== "test";

if (sentryOn) {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.RENDER ? "production" : "development",
    tracesSampleRate: 0.1,
  });
}

export { Sentry };
