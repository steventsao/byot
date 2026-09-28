import { APP_STORE_BADGE } from "./app-store-badge.ts";
import { APP_STORE_URL, REPO_URL, renderPage } from "./layout.ts";

// Frames rendered from the shipping app by OpenCodeAppStoreScreenshotHarness
// (docs/app-store). Reshoot there, then re-export into public/shots.
const shot = (name: string, alt: string, eager = false) =>
  `<div class="device"><img src="/shots/${name}.webp" alt="${alt}" width="660" height="1434"${eager ? ' fetchpriority="high"' : ' loading="lazy"'} decoding="async"></div>`;

const GALLERY = [
  ["03-answer-questions", "Answer questions", "Pick a choice or write your own.", "OpenCode asks which rate limiter to use, with three choices and a custom answer"],
  ["04-approve-permissions", "Approve permissions", "Allow once, always allow, or reject.", "A bash permission request with Allow once, Always allow, and Reject"],
  ["05-turn-complete", "Read the result", "Every tool call, with its output.", "The finished turn: all upload tests pass, with a summary of the changed files"],
  ["06-review-changes", "Review the diff", "Check the changes before you trust them.", "Session changes with expanded unified diffs"],
] as const;

const APP_FEATURES = [
  ["Live turns", "Assistant text, reasoning, and tool activity as it streams."],
  ["Your models", "Pick a model per prompt from your server’s own catalog."],
  ["Queue and steer", "Line up follow-up prompts while a turn runs."],
  ["Drafts that stay", "Unsent text and attachments survive session changes and relaunches."],
  ["Every server", "Switch saved servers. Browse by project or in one list, and search."],
  ["OpenCode 1 and 2", "The protocol is detected automatically."],
] as const;

const COMPANION_FEATURES = [
  ["Notifications", "Approvals, questions, finished turns, and errors."],
  ["Computer queue", "Accepted prompts run in order while BYOT is closed."],
] as const;

const rows = (items: readonly (readonly [string, string])[]) =>
  items.map(([title, detail]) => `<li><strong>${title}</strong><span>${detail}</span></li>`).join("");

const BODY = `
    <section class="wrap hero" aria-labelledby="hero-title">
      <div>
        <p class="eyebrow">OpenCode client for iPhone and iPad</p>
        <h1 id="hero-title"><span>Your coding agent,</span> <span>in your pocket.</span></h1>
        <p class="lede">BYOT connects straight to the OpenCode server on your own computer. Start turns, watch them stream, and review the diff from your phone.</p>
        <div class="actions">
          <a class="badge" href="${APP_STORE_URL}" aria-label="Download BYOT on the App Store">${APP_STORE_BADGE}</a>
          <a class="text-link" href="${REPO_URL}">View the source <span aria-hidden="true">→</span></a>
        </div>
        <ul class="facts" aria-label="At a glance"><li>No account</li><li>No analytics</li><li>Open source · MIT</li></ul>
      </div>
      <div class="stage">
        <div class="back">${shot("01-sessions", "Sessions across projects on a Mac mini server, with live Working and Idle status", true)}</div>
        <div class="front">${shot("02-live-turn", "A live turn streaming reasoning, search, read, write, and edit tool calls", true)}</div>
      </div>
    </section>

    <section class="section" id="features" aria-labelledby="features-title">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">The whole turn</p>
          <h2 id="features-title">Stay in the loop, away from your desk.</h2>
          <p>When OpenCode needs you, answer from wherever you are. Your server keeps working.</p>
        </div>
        <ul class="gallery">
          ${GALLERY.map(([name, title, detail, alt]) => `<li><figure>${shot(name, alt)}<figcaption><strong>${title}</strong><span>${detail}</span></figcaption></figure></li>`).join("\n          ")}
        </ul>
        <div class="columns">
          <div>
            <p class="group-title">In the app</p>
            <ul class="group">${rows(APP_FEATURES)}</ul>
          </div>
          <div>
            <p class="group-title">With the optional companion</p>
            <ul class="group">${rows(COMPANION_FEATURES)}</ul>
            <p class="group-note">The BYOT companion runs on your OpenCode computer. <a class="text-link" href="/support">Set it up <span aria-hidden="true">→</span></a></p>
          </div>
        </div>
      </div>
    </section>

    <section class="section" id="setup" aria-labelledby="setup-title">
      <div class="wrap columns">
        <div class="section-head">
          <p class="eyebrow">Bring your own server</p>
          <h2 id="setup-title">Your server does the work.</h2>
          <p>BYOT shows what OpenCode does and sends your instructions over HTTPS. Your code stays on your computer.</p>
        </div>
        <div>
          <ol class="group steps">
            <li><strong>Start OpenCode</strong><span>Run <code>opencode serve</code> with a password on your computer.</span></li>
            <li><strong>Make it reachable</strong><span>Serve it over HTTPS. <code>tailscale serve</code> is the usual path.</span></li>
            <li><strong>Add the server</strong><span>In BYOT, enter its URL, username, and password.</span></li>
          </ol>
          <p class="group-note"><a class="text-link" href="/support">Full setup guide <span aria-hidden="true">→</span></a></p>
        </div>
      </div>
    </section>

    <section class="section" aria-labelledby="privacy-title">
      <div class="wrap privacy">
        <div class="section-head">
          <p class="eyebrow">Privacy</p>
          <h2 id="privacy-title">Direct to your server.</h2>
        </div>
        <div class="privacy-copy">
          <p>There is no BYOT account and no analytics or tracking. Prompts and attachments go to your server and the model providers you enable there. Server passwords stay in the iOS Keychain.</p>
          <p>Optional notifications and the computer queue use the BYOT relay for delivery and encrypted queued content. <a href="/privacy">Read the privacy policy</a>.</p>
        </div>
      </div>
    </section>`;

export function renderLanding(): string {
  return renderPage({
    title: "BYOT — OpenCode client for iPhone and iPad",
    description:
      "A native iOS client for OpenCode. Connect to the OpenCode server on your own computer and drive coding sessions from your iPhone or iPad. No account, no analytics, open source.",
    path: "/",
    body: BODY,
  });
}
