import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../src/landing-worker.ts";

test("serves the landing page on both hosts, aliases, and campaign query strings", async () => {
  for (const host of ["byot.app", "www.byot.app"]) {
    for (const path of ["/", "/?ref=campaign", "/index.html", "/index.html?ref=campaign"]) {
      const response = await worker.fetch(new Request(`https://${host}${path}`));
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("content-type"), "text/html; charset=utf-8");
      assert.match(await response.text(), /id="setup"/);
    }
  }
});

test("HEAD has the same landing headers and no response body", async () => {
  const response = await worker.fetch(new Request("https://byot.app/", { method: "HEAD" }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "public, max-age=300");
  assert.equal(await response.text(), "");
});

test("forwards other routes, methods, and hosts without changing the request or response", async (t) => {
  let forwarded: Request | undefined;
  const upstream = new Response("upstream response", {
    status: 401,
    headers: { "www-authenticate": "Bearer", "cache-control": "private, no-store" },
  });
  t.mock.method(globalThis, "fetch", async (request: Request) => {
    forwarded = request;
    return upstream;
  });

  for (const url of [
    "https://byot.app/privacy",
    "https://byot.app/support?from=landing",
    "https://byot.app/api",
    "https://byot.app/api/t/example/ws",
    "https://byot.app/agents",
    "https://byot.app/play",
    "https://byot.app/health",
    "https://byot.app/missing",
    "https://example.byot.app/",
  ]) {
    const request = new Request(url, { headers: { authorization: "Bearer test-only" } });
    assert.equal(await worker.fetch(request), upstream);
    assert.equal(forwarded, request);
  }

  const request = new Request("https://byot.app/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ example: "must reach the dispatcher" }),
  });
  assert.equal(await worker.fetch(request), upstream);
  assert.equal(forwarded, request);
  assert.equal(request.bodyUsed, false);
  assert.deepEqual(await request.json(), { example: "must reach the dispatcher" });
});
