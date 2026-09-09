# BYOT landing page

Source for [byot.app](https://byot.app/), packaged separately from the iOS app.
`src/landing.ts` renders the page with inline styles and the official App Store
badge. It has no client-side JavaScript or external asset requests.

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
`www.byot.app/*`. It serves only GET and HEAD requests for `/` and `/index.html`,
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
