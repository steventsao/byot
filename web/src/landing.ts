import { APP_STORE_BADGE } from "./app-store-badge.ts";
import { FONT_STYLES } from "./fonts.ts";
import { icon } from "./icons.ts";
import { renderPreview, PREVIEW_SCRIPT } from "./preview.ts";
import { STYLES } from "./styles.ts";

const REPO_URL = "https://github.com/steventsao/byot";
const APP_STORE_URL = "https://apps.apple.com/us/app/byot/id6782403920";

export function renderLanding(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BYOT — OpenCode. In your pocket.</title>
  <meta name="description" content="Keep coding from your iPhone. BYOT is a free, open-source iOS client for OpenCode. Your machine, your models, your flow.">
  <meta name="theme-color" content="#080809">
  <meta name="apple-itunes-app" content="app-id=6782403920">
  <link rel="canonical" href="https://byot.app/">
  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='16' fill='%23080809'/%3E%3Ctext x='32' y='43' fill='%23eeeef0' font-family='system-ui,sans-serif' font-weight='700' font-size='25' text-anchor='middle'%3Ebyot%3C/text%3E%3C/svg%3E">
  <meta property="og:type" content="website">
  <meta property="og:title" content="BYOT — OpenCode. In your pocket.">
  <meta property="og:description" content="Keep coding from your iPhone. Your machine. Your models. Your flow.">
  <meta property="og:url" content="https://byot.app/">
  <meta name="twitter:card" content="summary">
  <style>${FONT_STYLES}\n${STYLES}</style>
  <noscript><style>.preview-tabs { display: none; }</style></noscript>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header">
    <div class="wrap header-inner">
      <a class="wordmark" href="/" aria-label="BYOT home">byot</a>
      <nav class="nav" aria-label="Main navigation">
        <a class="nav-link" href="#setup">Set up</a>
        <a class="nav-link nav-github" href="${REPO_URL}">GitHub ${icon("arrow")}</a>
        <a class="button" href="${APP_STORE_URL}" aria-label="Get BYOT on the App Store">Get the app ${icon("arrow")}</a>
      </nav>
    </div>
  </header>
  <main class="wrap" id="main" tabindex="-1">
    <section class="hero" aria-labelledby="hero-title">
      <div class="hero-copy">
        <p class="eyebrow"><span class="status-dot"></span>Native OpenCode client</p>
        <h1 id="hero-title"><span>OpenCode.</span><span class="quiet">In your pocket.</span></h1>
        <p class="hero-description"><span>Keep coding from your iPhone.</span>Your machine. Your models. Your flow.</p>
        <div class="hero-actions">
          <a class="app-store" href="${APP_STORE_URL}" aria-label="Download BYOT on the App Store">${APP_STORE_BADGE}</a>
          <a class="text-link" href="#experience">Take a look ${icon("down")}</a>
        </div>
        <p class="hero-note">${icon("github")}Free &amp; open source<span class="separator">·</span>iPhone &amp; iPad</p>
      </div>
      ${renderPreview()}
    </section>

    <section class="setup" id="setup" aria-labelledby="setup-title">
      <div class="setup-copy">
        <p class="section-label">Bring your own server</p>
        <h2 id="setup-title">Same setup.<br>A little more freedom.</h2>
        <p>Connect to OpenCode on your computer.<br>Pick up the conversation on your phone.</p>
        <a class="text-link" href="/support">Connection guide ${icon("arrow")}</a>
      </div>
      <div class="connection-card">
        <div class="connection-diagram" role="img" aria-label="Your iPhone connects directly to your computer over HTTPS">
          <div class="connection-node"><div class="connection-device">${icon("phone")}</div><span>Your iPhone</span></div>
          <div class="connection-line">${icon("lock")}</div>
          <div class="connection-node"><div class="connection-device">${icon("laptop")}</div><span>Your computer</span></div>
        </div>
        <p class="connection-caption">No account. No relay. Just your server.</p>
        <details>
          <summary>Connect your server</summary>
          <ol class="setup-steps">
            <li><span>Run <code>opencode serve</code> on your computer.</span></li>
            <li><span>Make it reachable over HTTPS with authentication. Tailscale works well.</span></li>
            <li><span>Add the server address in BYOT. You’re in.</span></li>
          </ol>
        </details>
      </div>
    </section>
  </main>
  <footer class="site-footer">
    <div class="wrap footer-inner">
      <div class="footer-brand"><a class="wordmark" href="/" aria-label="BYOT home">byot</a><p>Made for your own machine.</p></div>
      <nav class="footer-nav" aria-label="Footer navigation"><a href="/privacy">Privacy</a><a href="/support">Support</a><a href="${REPO_URL}">GitHub</a></nav>
    </div>
  </footer>
  <script>${PREVIEW_SCRIPT}</script>
</body>
</html>`;
}
