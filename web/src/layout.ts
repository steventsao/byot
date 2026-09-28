import { STYLES } from "./styles.ts";
import { WORDMARK_FONT } from "./wordmark-font.ts";

export const REPO_URL = "https://github.com/steventsao/byot";
export const APP_STORE_URL = "https://apps.apple.com/us/app/byot/id6782403920";

const FAVICON =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%23000'/%3E%3Ctext x='32' y='41' fill='%23fff' font-family='-apple-system,system-ui,sans-serif' font-size='22' font-weight='700' text-anchor='middle'%3Ebyot%3C/text%3E%3C/svg%3E";

interface Page {
  title: string;
  description: string;
  path: string;
  body: string;
}

export function renderPage({ title, description, path, body }: Page): string {
  const url = `https://byot.app${path}`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>${title}</title>
  <meta name="description" content="${description}">
  <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
  <meta name="apple-itunes-app" content="app-id=6782403920">
  <link rel="canonical" href="${url}">
  <link rel="icon" href="${FAVICON}">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="BYOT">
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${description}">
  <meta property="og:url" content="${url}">
  <meta property="og:image" content="https://byot.app/og.jpg">
  <meta property="og:image:width" content="1270">
  <meta property="og:image:height" content="760">
  <meta name="twitter:card" content="summary_large_image">
  <style>${WORDMARK_FONT}${STYLES}</style>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="bar">
    <div class="wrap bar-inner">
      <a class="wordmark" href="/" aria-label="byot home">byot</a>
      <nav class="nav" aria-label="Main">
        <a href="/#features">Features</a>
        <a href="/support">Support</a>
        <a href="${REPO_URL}">GitHub</a>
        <a class="pill" href="${APP_STORE_URL}">Get the app</a>
      </nav>
    </div>
  </header>
  <main id="main" tabindex="-1">
${body}
  </main>
  <footer class="footer">
    <div class="wrap footer-inner">
      <div class="footer-brand"><a class="wordmark" href="/" aria-label="byot home">byot</a><span>An independent client, not affiliated with the OpenCode project.</span></div>
      <nav aria-label="Footer"><a href="/privacy">Privacy</a><a href="/support">Support</a><a href="${REPO_URL}">GitHub</a></nav>
    </div>
  </footer>
</body>
</html>`;
}
