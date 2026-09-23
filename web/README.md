# BYOT landing page

Source for [byot.app](https://byot.app/), packaged separately from the iOS app.
`src/landing.ts` renders the page with the iOS app's Open Runde typography, Dark
appearance, and rounded controls. The preview switches between a session, diff,
and permission request using a small inline script. All preview interactions stay
in the browser; the page has no external asset requests or tracking.

`src/styles.ts` holds the styles and `src/preview.ts` holds the illustrative app
preview and its keyboard-accessible tabs. The real iOS app remains the source of
truth for product behavior.

## Preview

Run `npm run dev` from `web/` and open `http://127.0.0.1:4173`. The development
server watches source changes. Reload the browser to see updates. Support and
privacy links open the existing production pages.

## Typography

The generated `src/fonts.ts` embeds Latin WOFF2 subsets of the app's Open Runde
Regular and Semibold fonts, with the complete SIL Open Font License. Regenerate
from the repository's original fonts with:

```sh
uv run --with fonttools --with brotli scripts/build-fonts.py
```

The official App Store badge artwork is preserved in `src/app-store-badge.ts`.

## Validate

Requires Node.js 22.18 or later. From `web/`:

```sh
npm ci
npm run typecheck
npm test
npm run build
```

The build command bundles the Worker locally without publishing it. Tests cover
the homepage and its aliases, query strings, HEAD requests, and forwarding of
other paths and request bodies.

## Deployment

From `web/`, with Wrangler authenticated to the BYOT Cloudflare account:

```sh
npm run deploy
```

`wrangler.jsonc` deploys `byot-landing` on the standard routes `byot.app/*` and
`www.byot.app/*`. It serves GET and HEAD requests for `/`, `/index.html`, `/privacy`, and `/support`,
including query strings. Other requests are forwarded unchanged to the existing
`byot-dispatcher` Custom Domain worker. More specific API, task, and agent routes
retain precedence; tenant subdomains and email routing keep their existing paths.

Cloudflare rejected updates to the legacy dispatcher on September 9, 2026 with
code 10121 because the account no longer has access to its Workers for Platforms
dispatch namespace. This landing Worker requires no bindings or Workers for
Platforms subscription. Keep the original dispatcher and its Custom Domains
intact. Removing the two `byot-landing` routes restores its previous homepage.

This routing behavior is documented in
[Cloudflare's Routes guide](https://developers.cloudflare.com/workers/configuration/routing/routes/).
