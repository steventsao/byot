// Mirrors BYOTBrand: system type for prose, monospace for code, the Open Runde
// wordmark, 16-point radii, semantic system fills, and the forest/mint accent.
// Light and Dark follow the visitor's appearance, as the app does by default.
export const STYLES = `
:root {
  color-scheme: light dark;
  --canvas: #ffffff;
  --grouped: #f2f2f7;
  --surface: #ffffff;
  --fill: #7676801f;
  --ink: #000000;
  --muted: #6c6c70;
  --faint: #8e8e93;
  --hairline: #3c3c432e;
  --accent: #1f6142;
  --accent-soft: #1f614214;
  --action: #000000;
  --action-ink: #ffffff;
  --bar: #ffffffcc;
  --shot-shadow: 0 30px 60px -30px #0000004d, 0 0 0 1px #0000001a;
  --radius: 16px;
  --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --display: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --canvas: #000000;
    --grouped: #000000;
    --surface: #1c1c1e;
    --fill: #7676803d;
    --ink: #ffffff;
    --muted: #98989f;
    --faint: #6c6c70;
    --hairline: #54545899;
    --accent: #8ae0b3;
    --accent-soft: #8ae0b31f;
    --action: #ffffff;
    --action-ink: #000000;
    --bar: #000000b3;
    --shot-shadow: 0 30px 80px -30px #8ae0b31f, 0 0 0 1px #ffffff26;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; scroll-behavior: smooth; scroll-padding-top: 72px; }
body { margin: 0; background: var(--canvas); color: var(--ink); font: 17px/1.5 var(--sans); letter-spacing: -.01em; -webkit-font-smoothing: antialiased; }
h1, h2, h3, p, ol, ul { margin: 0; }
h1, h2 { text-wrap: balance; }
p { text-wrap: pretty; }
a { color: inherit; text-decoration: none; }
code { font: .88em var(--mono); letter-spacing: 0; }
img { display: block; max-width: 100%; }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; border-radius: 8px; }
::selection { background: var(--accent-soft); }
.wrap { width: min(1080px, calc(100% - 48px)); margin-inline: auto; }
.skip-link { position: absolute; z-index: 20; top: 10px; left: 16px; padding: 10px 16px; border-radius: 12px; background: var(--action); color: var(--action-ink); transform: translateY(-160%); }
.skip-link:focus { transform: none; }

/* Navigation bar: translucent material with a hairline, like the app's chrome. */
.bar { position: sticky; top: 0; z-index: 10; background: var(--bar); -webkit-backdrop-filter: saturate(180%) blur(20px); backdrop-filter: saturate(180%) blur(20px); border-bottom: .5px solid var(--hairline); }
.bar-inner { display: flex; align-items: center; justify-content: space-between; gap: 24px; height: 60px; }
.wordmark { font-family: "Open Runde", var(--display); font-weight: 700; font-size: 24px; letter-spacing: -.02em; line-height: 1; }
.nav { display: flex; align-items: center; gap: 28px; font-size: 15px; }
.nav a:not(.pill) { color: var(--muted); transition: color .18s; }
.nav a:not(.pill):hover { color: var(--ink); }
.pill { display: inline-flex; align-items: center; min-height: 36px; padding: 0 16px; border-radius: 999px; background: var(--action); color: var(--action-ink); font-size: 15px; font-weight: 600; transition: opacity .18s; }
.pill:hover { opacity: .82; }

/* Hero */
.hero { display: grid; grid-template-columns: 1.2fr 1fr; align-items: center; gap: 48px; padding-block: 88px 96px; }
.eyebrow { font: 600 13px/1 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--accent); }
h1 { margin-top: 20px; font: 700 clamp(40px, 5.2vw, 60px)/1.05 var(--display); letter-spacing: -.035em; }
h1 span { display: block; }
@media (min-width: 641px) { h1 span { white-space: nowrap; } }
.lede { margin-top: 22px; max-width: 30em; font-size: 19px; line-height: 1.5; color: var(--muted); }
.actions { display: flex; flex-wrap: wrap; align-items: center; gap: 24px; margin-top: 32px; }
.badge { display: inline-flex; border-radius: 9px; transition: opacity .18s; }
.badge:hover { opacity: .85; }
.badge svg { width: 150px; height: 50px; display: block; }
.text-link { display: inline-flex; align-items: center; gap: 6px; min-height: 44px; font-weight: 600; color: var(--accent); }
.text-link span { transition: transform .18s; }
.text-link:hover span { transform: translateX(3px); }
.facts { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 28px; padding: 0; list-style: none; }
.facts li { display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: 999px; background: var(--fill); font-size: 14px; font-weight: 500; }
.facts li::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); }

/* Real app screenshots in a thin device outline. */
.device { position: relative; aspect-ratio: 1320 / 2868; border-radius: 13% / 6%; overflow: hidden; background: #000; box-shadow: var(--shot-shadow); }
.device img { width: 100%; height: 100%; object-fit: cover; }
.stage { position: relative; display: flex; justify-content: center; align-items: flex-end; min-height: 560px; }
.stage .device { width: 272px; }
.stage .front { z-index: 2; margin-left: 96px; }
.stage .back { position: absolute; width: 240px; left: calc(50% - 212px); bottom: 36px; }

/* Sections */
.section { padding-block: 96px; border-top: .5px solid var(--hairline); }
.section-head { max-width: 640px; }
.section-head h2 { margin-top: 14px; font: 700 clamp(32px, 4vw, 44px)/1.1 var(--display); letter-spacing: -.03em; }
.section-head p:not(.eyebrow) { margin-top: 14px; font-size: 18px; color: var(--muted); }
.gallery { display: grid; grid-template-columns: repeat(4, 1fr); gap: 28px; margin-top: 56px; padding: 0; list-style: none; }
.gallery figure { margin: 0; }
.gallery figcaption { margin-top: 20px; }
.gallery strong { display: block; font-size: 17px; font-weight: 600; }
.gallery figcaption span { display: block; margin-top: 4px; font-size: 15px; color: var(--muted); }

/* Inset grouped lists, the app's settings style. */
.columns { display: grid; grid-template-columns: 1fr 1fr; gap: 40px; margin-top: 56px; }
.group-title { padding-inline: 16px; margin-bottom: 8px; font-size: 13px; text-transform: uppercase; letter-spacing: .02em; color: var(--muted); }
.group { padding: 0; list-style: none; border-radius: var(--radius); background: var(--grouped); overflow: hidden; }
@media (prefers-color-scheme: dark) { .group { background: var(--surface); } }
.group li { position: relative; padding: 14px 16px; }
.group li + li::before { content: ""; position: absolute; top: 0; left: 16px; right: 0; border-top: .5px solid var(--hairline); }
.group strong { display: block; font-weight: 600; }
.group span { display: block; margin-top: 2px; font-size: 15px; color: var(--muted); }
.group-note { padding: 8px 16px 0; font-size: 13px; color: var(--muted); }
.steps { counter-reset: step; }
.steps li { display: grid; grid-template-columns: 28px 1fr; column-gap: 8px; }
.steps li::after { counter-increment: step; content: counter(step); grid-row: 1 / span 2; grid-column: 1; display: grid; place-items: center; width: 24px; height: 24px; margin-top: 1px; border-radius: 50%; background: var(--accent-soft); color: var(--accent); font-size: 13px; font-weight: 700; }
.steps li > * { grid-column: 2; }
.privacy { display: grid; grid-template-columns: 1fr 1fr; gap: 40px; align-items: start; }
.privacy-copy p { color: var(--muted); font-size: 17px; }
.privacy-copy p + p { margin-top: 14px; }
.privacy-copy a { color: var(--accent); font-weight: 500; }

/* Footer */
.footer { border-top: .5px solid var(--hairline); padding-block: 36px 48px; font-size: 14px; color: var(--muted); }
.footer-inner { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 16px 32px; }
.footer .wordmark { color: var(--ink); font-size: 20px; }
.footer-brand { display: flex; align-items: center; gap: 16px; }
.footer nav { display: flex; gap: 24px; }
.footer nav a:hover { color: var(--ink); }

/* Information pages */
.doc { max-width: 680px; padding-block: 64px 96px; }
.doc h1 { margin-top: 12px; font-size: clamp(36px, 5vw, 48px); }
.doc .updated { margin-top: 12px; font-size: 15px; color: var(--muted); }
.doc-body { margin-top: 36px; }
.doc-body p, .doc-body ol, .doc-body ul { margin-top: 14px; color: var(--ink); }
.doc-body h2 { margin-top: 44px; font: 700 22px/1.25 var(--display); letter-spacing: -.02em; }
.doc-body ol, .doc-body ul { padding-left: 1.3em; }
.doc-body li { margin-top: 8px; padding-left: 4px; }
.doc-body li::marker { color: var(--muted); }
.doc-body a { color: var(--accent); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; }

@media (max-width: 900px) {
  .hero { grid-template-columns: 1fr; gap: 56px; padding-block: 56px 72px; text-align: center; }
  .lede { margin-inline: auto; }
  .actions, .facts { justify-content: center; }
  .gallery { grid-template-columns: repeat(4, 64%); overflow-x: auto; scroll-snap-type: x mandatory; scrollbar-width: none; margin-inline: -24px; padding-inline: 24px; scroll-padding-inline: 24px; }
  .gallery::-webkit-scrollbar { display: none; }
  .gallery li { scroll-snap-align: start; }
  .columns, .privacy { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  .nav a:not(.pill) { display: none; }
  .section { padding-block: 72px; }
  .stage { min-height: 0; }
  .stage .device { width: 232px; }
  .stage .front { margin-left: 72px; }
  .stage .back { width: 200px; left: calc(50% - 160px); bottom: 28px; }
  .gallery { grid-template-columns: repeat(4, 74%); gap: 20px; }
  .footer-inner { flex-direction: column; align-items: flex-start; }
}
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  * { transition: none !important; }
}
`;
