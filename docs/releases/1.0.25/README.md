# byot 1.0.25 — restore the previous provider experience

At the product owner's request, this release removes the provider OAuth/API-key onboarding introduced in 1.0.24. The session list and model picker again use providers configured on the OpenCode server. Existing model selection, server password authentication, typography, and swipe-to-archive retain their previous behavior.

Issue [#7](https://github.com/steventsao/byot/issues/7) is **deferred**, remains open with `priority:p3`, and requires a new product decision before further work. Feature [PR #72](https://github.com/steventsao/byot/pull/72) was closed without merging. The implementation remains in Git history.

## Verification

Application source commit: `d6c235957ec38bae2565402816cac07e1c1a86a4`.

- [Rollback comparison](rollback-verification.json): all files in `Sources`, `Tests`, and `scripts/e2e` exactly match the pre-feature tree at `fb19e16` (shipped app source 1.0.23 at `c7a475d`). Only release metadata and notes change the app from that baseline.
- [Signed archive verification](release-verification.json): version 1.0.25, build 20260918151913, arm64, valid strict signature, no provider onboarding implementation or DEBUG auth fixtures in the executable. All 111 archive source files match the local rollback source.
- [Withdrawal receipt](withdraw-1.0.24.json) and [independent group lookup](withdrawn-build-groups.json): 1.0.24 has no beta group membership after removal from Internal Testers.
- [Apple archive validation](apple-validation.txt) returned `VERIFY SUCCEEDED with no errors`.
- A fresh simulator regression run was attempted but could not start: the new simulator stalled waiting for BackBoard, and the previously used test simulator also stalled during startup. Both attempts were stopped and the owned simulators shut down. No new simulator pass is claimed; the unchanged application source retains the [1.0.23 release verification](../1.0.23/README.md).
- [GitHub issue state](issue-7-deferred.json) records the deferral.

The release uses synthetic simulator fixtures for UI checks; no provider login is performed or required for this rollback.

## Distribution

**Available to Internal Testers:** 1.0.25 (20260918151913), build `724a3be7-f10d-41ea-be6d-bd91a522c88c`. App Store Connect independently confirms `VALID`, `IN_BETA_TESTING`, explicit Internal Testers membership, and en-US notes matching `asc/testflight-notes.md`. Users on 1.0.24 can update to this newer build to restore the previous provider experience. No App Store release or external beta review was submitted.

Receipts: [publish](testflight-publish.json), [build](app-store-connect-build.json), [beta state](beta-detail.json), [group membership](beta-groups.json), [notes](testflight-notes.json).
