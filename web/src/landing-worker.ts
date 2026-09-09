import { renderLanding } from "./landing.ts";

const LANDING_HOSTS = new Set(["byot.app", "www.byot.app"]);

// A route in front of the existing dispatcher Custom Domain. This lets the
// public landing page deploy without changing its Workers for Platforms binding.
export default {
  fetch(request: Request): Response | Promise<Response> {
    const url = new URL(request.url);
    if (
      LANDING_HOSTS.has(url.hostname) &&
      (request.method === "GET" || request.method === "HEAD") &&
      (url.pathname === "/" || url.pathname === "/index.html")
    ) {
      return new Response(request.method === "HEAD" ? null : renderLanding(), {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }

    // Route subrequests reach the original Custom Domain worker, not this route.
    // Forward the original request so bodies, credentials, and streams survive.
    return fetch(request);
  },
} satisfies ExportedHandler;
