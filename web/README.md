# BYOT landing page

Source for [byot.app](https://byot.app/): the home page, `/privacy`, and
`/support`, packaged separately from the iOS app. The pages follow the app's
design: system type for prose, monospace for code, the Open Runde `byot`
wordmark, 16-point radii, inset grouped lists, and the forest (Light) and mint
(Dark) accent. They follow the visitor's Light or Dark appearance and have no
client-side JavaScript, tracking, or third-party requests.

- `src/landing.ts` renders the home page. `src/information.ts` holds the
  privacy and support text. `src/layout.ts` is the shared shell.
- `src/styles.ts` mirrors `BYOTBrand` tokens.
- `public/shots/` holds the iPhone App Store frames from
  `docs/app-store/screenshots/en-US/iphone-6.9/`, re-encoded as 660-pixel WebP:
  `cwebp -q 82 -resize 660 0 <frame>.png -o public/shots/<frame>.webp`.
- `src/wordmark-font.ts` embeds Open Runde Bold, subset to the wordmark glyphs:
  `uv run --with fonttools --with brotli scripts/build-wordmark-font.py`.
- `node scripts/render-static.ts <dir>` writes the pages and assets to a folder
  for offline review.

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
including query strings, and the files in `public/` as static assets. Other requests are forwarded unchanged to the existing
`byot-dispatcher` Custom Domain worker. More specific API, task, and agent routes
retain precedence; tenant subdomains and email routing keep their existing paths.

Cloudflare rejected updates to the legacy dispatcher on September 9, 2026 with
code 10121 because the account no longer has access to its Workers for Platforms
dispatch namespace. This landing Worker requires no bindings or Workers for
Platforms subscription. Keep the original dispatcher and its Custom Domains
intact. Removing the two `byot-landing` routes restores its previous homepage.

This routing behavior is documented in
[Cloudflare's Routes guide](https://developers.cloudflare.com/workers/configuration/routing/routes/).
