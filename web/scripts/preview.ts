import { createServer } from "node:http";
import { renderLanding } from "../src/landing.ts";

const port = Number(process.env.PORT ?? 4173);
createServer((request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(request.method === "HEAD" ? undefined : renderLanding());
    return;
  }
  // Support and privacy remain on the existing production site.
  response.writeHead(302, { location: `https://byot.app${url.pathname}${url.search}` });
  response.end();
}).listen(port, "127.0.0.1", () => {
  console.log(`BYOT landing preview: http://127.0.0.1:${port}`);
});
