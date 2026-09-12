// Mirrors BYOTBrand's Dark appearance, 16-point controls, and Open Runde type.
export const STYLES = `
:root {
  color-scheme: dark;
  --canvas: #080809;
  --surface: #1c1c1e;
  --elevated: #242426;
  --ink: #eeeef0;
  --muted: #97979f;
  --accent: #8ae0b3;
  --accent-soft: #15231c;
  --hairline: #ffffff14;
  --radius: 16px;
  --font: "Open Runde", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --mono: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 28px; }
body { margin: 0; background: var(--canvas); color: var(--ink); font: 16px/1.6 var(--font); -webkit-font-smoothing: antialiased; }
button, a { -webkit-tap-highlight-color: transparent; }
button { font: inherit; }
button, summary { cursor: pointer; }
a { color: inherit; text-decoration: none; }
button, a, summary { touch-action: manipulation; }
button:focus-visible, a:focus-visible, summary:focus-visible, [tabindex]:focus-visible { outline: 2px solid var(--accent); outline-offset: 5px; }
button { color: inherit; }
::selection { background: #8ae0b344; color: #fff; }
[hidden] { display: none !important; }
h1, h2, h3, p { margin: 0; }
.wrap { width: min(1120px, calc(100% - 80px)); margin-inline: auto; }
.icon { flex-shrink: 0; vertical-align: middle; }
.skip-link { position: absolute; z-index: 10; top: 12px; left: 16px; padding: 12px 20px; border-radius: 12px; background: var(--ink); color: var(--canvas); transform: translateY(-150%); }
.skip-link:focus { transform: none; }
.site-header { border-bottom: 1px solid var(--hairline); }
.header-inner { height: 100px; display: flex; align-items: center; justify-content: space-between; gap: 32px; }
.wordmark { display: inline-flex; align-items: center; min-height: 44px; font-size: 32px; font-weight: 600; letter-spacing: -.07em; line-height: 1; }
.nav { display: flex; align-items: center; gap: 32px; font-size: 13px; }
.nav-link { display: inline-flex; min-height: 44px; align-items: center; gap: 8px; color: var(--muted); transition: color .18s; }
.nav-link:hover { color: var(--ink); }
.nav-link .icon { width: 15px; height: 15px; }
.button { display: inline-flex; align-items: center; justify-content: center; gap: 12px; min-height: 44px; padding: 10px 18px; background: var(--ink); color: #09090b; border-radius: 13px; font-size: 13px; font-weight: 600; transition: background .18s, transform .18s; }
.button:hover { background: #fff; transform: translateY(-1px); }
.button .icon { width: 16px; height: 16px; }
.hero { display: grid; grid-template-columns: 1.12fr 1fr; align-items: center; gap: 64px; padding-block: 72px 68px; }
.hero-copy { padding-bottom: 70px; }
.eyebrow { display: flex; align-items: center; gap: 9px; color: var(--muted); font-size: 11px; font-weight: 600; letter-spacing: .11em; text-transform: uppercase; }
.eyebrow .status-dot { width: 6px; height: 6px; }
h1 { margin-top: 26px; font-weight: 600; font-size: clamp(48px, 5.35vw, 76px); line-height: 1.08; letter-spacing: -.065em; }
h1 span { display: block; white-space: nowrap; }
h1 .quiet { color: var(--muted); }
.hero-description { margin-top: 25px; color: var(--muted); font-size: 17px; line-height: 1.8; letter-spacing: -.015em; }
.hero-description span { display: block; }
.hero-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 26px; margin-top: 32px; }
.app-store { display: inline-flex; border-radius: 11px; transition: transform .18s; }
.app-store:hover { transform: translateY(-2px); }
.app-store svg { width: 160px; height: auto; display: block; }
.text-link { display: inline-flex; align-items: center; gap: 8px; min-height: 44px; font-size: 13px; }
.text-link .icon { width: 16px; height: 16px; transition: transform .18s; }
.text-link:hover .icon { transform: translateY(2px); }
.hero-note { display: flex; align-items: center; gap: 8px; margin-top: 24px; color: var(--muted); font-size: 11px; }
.hero-note .icon { width: 14px; height: 14px; }
.hero-note .separator { margin-inline: 4px; color: #676770; }

/* The preview follows the app's toolbar, tool cards, and bottom composer. */
.preview { width: 100%; min-width: 0; display: flex; flex-direction: column; align-items: center; scroll-margin-top: 28px; }
.phone-shell { position: relative; width: 326px; padding: 7px; border-radius: 47px; border: 1px solid #ffffff30; background: linear-gradient(145deg, #353538, #121214 30%, #2e2e30 85%, #424246); box-shadow: 0 35px 70px -20px #000, 0 0 0 1px #000, inset 0 0 0 2px #ffffff08; }
.phone-shell::before, .phone-shell::after { content: ""; position: absolute; width: 3px; border-radius: 2px; background: #353537; }
.phone-shell::before { left: -4px; top: 135px; height: 45px; box-shadow: 0 55px #353537; }
.phone-shell::after { right: -4px; top: 175px; height: 64px; }
.phone-screen { display: flex; flex-direction: column; height: 666px; overflow: hidden; border-radius: 39px; background: #000; border: 1px solid #000; }
.status-bar { display: flex; align-items: center; justify-content: space-between; position: relative; height: 49px; flex-shrink: 0; padding: 5px 21px 0 24px; font-size: 12px; font-weight: 600; }
.dynamic-island { position: absolute; top: 11px; left: 50%; width: 94px; height: 27px; transform: translateX(-50%); border-radius: 20px; background: #080809; }
.status-icons { display: flex; align-items: center; gap: 5px; }
.battery { display: block; position: relative; width: 22px; height: 11px; border: 1px solid #aaa; border-radius: 3px; }
.battery::before { position: absolute; content: ""; inset: 2px; background: var(--ink); border-radius: 1px; }
.battery::after { position: absolute; content: ""; right: -3px; top: 3px; height: 3px; width: 1px; background: #aaa; }
.app-toolbar { display: flex; align-items: center; gap: 5px; padding: 5px 12px 10px; }
.toolbar-control { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; background: #1c1c1e; border: 1px solid var(--hairline); flex-shrink: 0; }
.toolbar-control .icon { width: 17px; height: 17px; }
.session-title { font-size: 11px; font-weight: 600; letter-spacing: -.035em; flex: 1; text-align: center; }
.app-connection { display: flex; align-items: center; justify-content: center; gap: 6px; color: #b0b0b8; font-size: 9px; padding-bottom: 15px; }
.status-dot { display: inline-block; width: 5px; height: 5px; flex-shrink: 0; border-radius: 50%; background: var(--accent); }
.connection-divider { color: #62626b; margin-inline: 3px; }
.preview-panels { flex: 1; min-height: 0; display: flex; }
.preview-panel { width: 100%; padding: 4px 13px 12px; overflow-y: auto; scrollbar-width: thin; }
.user-message { width: fit-content; max-width: 85%; padding: 12px 14px; margin: 2px 0 24px auto; background: #242426; border-radius: var(--radius); font-size: 12px; line-height: 1.55; letter-spacing: -.015em; }
.agent-label { display: flex; align-items: center; gap: 7px; color: #acacb5; font-size: 10px; font-weight: 600; margin-bottom: 9px; }
.agent-label .icon { width: 15px; height: 15px; color: var(--accent); }
.agent-message { font-size: 12px; line-height: 1.7; margin-bottom: 14px; }
.tool-card { display: flex; gap: 8px; align-items: center; background: #1c1c1e; border: 1px solid #ffffff0f; border-radius: 13px; margin-block: 7px; padding: 11px 10px; }
.tool-icon { align-self: flex-start; display: grid; place-items: center; width: 13px; height: 13px; border-radius: 50%; color: #14271d; background: var(--accent); margin-top: 2px; }
.tool-icon .icon { width: 9px; height: 9px; stroke-width: 2.8; }
.tool-card strong { display: block; font-size: 11px; font-weight: 600; line-height: 1.4; }
.tool-card div > span { display: block; margin-top: 3px; color: #a2a2ac; font: 9px/1.5 var(--mono); }
.tool-chevron { margin-left: auto; color: #adadb6; }
.tool-chevron .icon { width: 13px; height: 13px; }
.change-count { margin-left: auto; font: 9px var(--mono); color: var(--accent); white-space: nowrap; }
.change-count i { color: #d0a29f; font-style: normal; margin-left: 4px; }
.result-label { margin-top: 20px; margin-bottom: 6px; }
.result-message { margin-bottom: 13px; }
.result-message span { color: var(--muted); }
.turn-status { display: flex; align-items: center; gap: 5px; color: var(--accent); font-size: 9px; }
.turn-status .icon { width: 12px; height: 12px; }
.elapsed { margin-left: auto; color: var(--muted); }
.app-composer { flex-shrink: 0; padding: 10px 12px 0; background: #151517; border-top: 1px solid var(--hairline); }
.composer-options { display: flex; gap: 6px; margin-bottom: 8px; }
.composer-options > span { display: inline-flex; align-items: center; gap: 4px; padding: 4px 8px; background: #242426; border-radius: 20px; font-size: 8px; font-weight: 600; }
.composer-options .icon { width: 11px; height: 11px; }
.composer-input { display: flex; align-items: center; gap: 8px; }
.composer-input > span:first-child { flex: 1; align-self: stretch; display: flex; align-items: center; padding-inline: 12px; background: #242426; color: #9999a2; border-radius: 12px; font-size: 11px; }
.send-control { display: grid; place-items: center; width: 35px; height: 35px; background: var(--ink); color: #09090b; border-radius: 12px; }
.send-control .icon { width: 19px; height: 19px; stroke-width: 2; }
.home-indicator { width: 103px; height: 4px; background: var(--ink); border-radius: 4px; margin: 16px auto 7px; }
.preview-tabs { display: flex; gap: 3px; margin-top: 28px; padding: 4px; border: 1px solid var(--hairline); border-radius: var(--radius); background: #111113; }
.preview-tabs button { display: flex; align-items: center; justify-content: center; gap: 5px; background: transparent; border: 0; min-height: 40px; padding: 8px 12px; border-radius: 11px; color: var(--muted); font-size: 11px; transition: color .18s, background .18s; }
.preview-tabs button[aria-selected="true"] { background: #2a2a2d; color: #f4f4f5; }
.preview-tabs button:hover { color: var(--ink); }
.preview-tabs .icon { width: 14px; height: 14px; }
.preview-caption { margin-top: 13px; color: var(--muted); font-size: 10px; }
.panel-heading { margin: 8px 0 24px; }
.panel-heading p { font-size: 11px; color: var(--muted); margin-top: 4px; }
.panel-heading .panel-title { color: var(--ink); font-size: 24px; font-weight: 600; letter-spacing: -.045em; }
.diff-summary { display: flex; align-items: center; gap: 7px; font-size: 10px; color: var(--muted); margin-bottom: 12px; }
.diff-summary .icon { width: 15px; height: 15px; }
.diff-card { overflow: hidden; border: 1px solid #ffffff1c; border-radius: var(--radius); background: #131315; }
.diff-filename { display: flex; align-items: center; gap: 6px; padding: 13px 10px; font: 9px var(--mono); color: #c0c0c8; }
.diff-filename .icon { width: 13px; height: 13px; }
.diff-code { padding-block: 8px 12px; font: 9px/2.4 var(--mono); }
.diff-code > div { padding-inline: 10px; white-space: pre; }
.code-context { color: var(--muted); }
.code-added { background: #172a20; color: #a3dfbc; }
.code-removed { background: #2d1d1e; color: #e0b0b4; }
.review-note { display: flex; align-items: center; gap: 6px; margin-top: 16px; color: var(--accent); font-size: 10px; }
.review-note .icon { width: 13px; height: 13px; }
.permission-card { padding: 17px 13px; border: 1px solid #ffffff20; background: var(--surface); border-radius: var(--radius); margin-top: 22px; }
.permission-heading { display: flex; align-items: center; gap: 8px; font-size: 15px; }
.permission-heading .icon { width: 19px; height: 19px; color: var(--accent); }
.permission-card p { color: #b4b4bd; font-size: 11px; margin-top: 12px; }
.permission-card code { display: block; margin-block: 12px; padding: 10px; background: #0006; border-radius: 8px; font: 11px var(--mono); }
.permission-actions { display: flex; flex-wrap: wrap; gap: 5px; }
.permission-actions button { flex: 1 1 auto; border: 1px solid #ffffff24; border-radius: 9px; padding: 9px 7px; min-height: 44px; background: #2c2c30; font-size: 9px; }
.permission-actions button:nth-child(2) { background: var(--ink); color: #09090b; }
.permission-actions button[aria-pressed="true"] { box-shadow: 0 0 0 2px var(--accent); }
.permission-result { min-height: 44px; margin-top: 16px; color: var(--muted); font-size: 10px; line-height: 1.7; }

.setup { display: grid; grid-template-columns: 1fr 1fr; gap: 90px; align-items: center; padding-block: 82px 88px; }
.section-label { color: var(--muted); font-size: 10px; font-weight: 600; letter-spacing: .13em; text-transform: uppercase; }
.setup h2 { margin-top: 18px; font-size: 39px; line-height: 1.2; letter-spacing: -.05em; font-weight: 600; }
.setup-copy > p:last-of-type { max-width: 330px; margin-top: 19px; color: var(--muted); font-size: 14px; }
.setup-copy > .text-link { margin-top: 15px; }
.connection-card { padding: 28px 30px 0; background: #141416; border: 1px solid var(--hairline); border-radius: var(--radius); }
.connection-diagram { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.connection-node { text-align: center; }
.connection-device { display: grid; place-items: center; width: 62px; height: 62px; border: 1px solid #ffffff12; background: #1c1c1e; border-radius: var(--radius); }
.connection-device .icon { width: 28px; height: 28px; stroke-width: 1.3; }
.connection-node > span { display: block; margin-top: 9px; font-size: 10px; color: #b1b1ba; }
.connection-line { display: flex; align-items: center; flex: 1; gap: 11px; padding-bottom: 27px; color: var(--accent); }
.connection-line::before, .connection-line::after { content: ""; flex: 1; height: 1px; background: #8ae0b336; }
.connection-line .icon { width: 16px; height: 16px; }
.connection-caption { padding-block: 22px; text-align: center; color: var(--muted); font-size: 11px; }
details { border-top: 1px solid var(--hairline); }
summary { display: flex; align-items: center; justify-content: space-between; min-height: 62px; gap: 10px; list-style: none; font-size: 12px; }
summary::-webkit-details-marker { display: none; }
summary::after { content: "+"; color: var(--muted); font-size: 22px; font-weight: 400; }
details[open] summary::after { content: "−"; }
.setup-steps { display: grid; gap: 14px; padding: 0 0 24px; margin: 0; list-style: none; counter-reset: step; }
.setup-steps li { counter-increment: step; display: grid; grid-template-columns: 19px 1fr; gap: 9px; color: #b1b1b9; font-size: 12px; }
.setup-steps li::before { content: "0" counter(step); color: var(--accent); font-size: 10px; padding-top: 2px; }
.setup-steps code { color: var(--ink); font: 11px var(--mono); }
.site-footer { border-top: 1px solid var(--hairline); }
.footer-inner { display: flex; align-items: center; justify-content: space-between; gap: 30px; min-height: 108px; }
.footer-brand { display: flex; align-items: center; gap: 20px; }
.footer-brand .wordmark { font-size: 26px; }
.footer-brand p { color: var(--muted); font-size: 11px; }
.footer-nav { display: flex; gap: 24px; font-size: 11px; color: var(--muted); }
.footer-nav a { display: inline-flex; align-items: center; min-height: 44px; }
.footer-nav a:hover { color: var(--ink); }

@media (min-width: 1500px) { .hero { gap: 80px; padding-top: 84px; } }
@media (max-width: 1050px) {
  .hero { gap: 25px; grid-template-columns: 1.12fr 1fr; }
  h1 { font-size: clamp(46px, 5.5vw, 60px); }
  .hero-actions { gap: 16px; }
  .hero-description { font-size: 15px; }
  .setup { gap: 50px; }
  .setup h2 { font-size: 34px; }
}
@media (max-width: 760px) {
  .wrap { width: calc(100% - 40px); }
  .header-inner { height: 82px; gap: 20px; }
  .wordmark { font-size: 29px; }
  .nav { gap: 22px; }
  .nav-github { display: none; }
  .hero { grid-template-columns: 1fr; gap: 45px; padding-block: 56px 42px; }
  .hero-copy { padding-bottom: 0; text-align: center; }
  .eyebrow, .hero-actions, .hero-note { justify-content: center; }
  h1 { font-size: clamp(43px, 8.5vw, 62px); margin-top: 22px; }
  .hero-description { font-size: 15px; margin-top: 22px; }
  .hero-actions { margin-top: 25px; gap: 22px; }
  .hero-note { margin-top: 18px; }
  .phone-shell { width: 326px; max-width: calc(100% - 8px); }
  .setup { grid-template-columns: 1fr; gap: 32px; padding-block: 48px; }
  .setup h2 { font-size: 34px; }
  .setup-copy > p:last-of-type { max-width: 100%; }
  .connection-card { padding-inline: 24px; }
  .footer-inner { flex-wrap: wrap; justify-content: center; gap: 8px; padding-block: 25px; }
  .footer-brand { width: 100%; justify-content: center; gap: 17px; }
  .footer-nav { gap: 26px; }
}
@media (max-width: 370px) {
  .wrap { width: calc(100% - 32px); }
  .nav { gap: 13px; }
  .button { padding-inline: 12px; }
  h1 { font-size: 41px; }
  .hero-actions { gap: 14px; }
  .app-store svg { width: 145px; }
  .text-link { font-size: 12px; }
  .phone-shell { padding: 5px; }
  .session-title { font-size: 10px; }
  .preview-tabs button { padding-inline: 9px; font-size: 10px; }
}
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  *, *::before, *::after { transition: none !important; }
}
`;
