# App Store submission — BYOT 1.0.23

Submitted September 15, 2026 at 10:56 PDT with TestFlight build **20260915103231**. The App Store version and review submission are both **WAITING_FOR_REVIEW**, and `asc status` reports no blocking issues. The live App Store version is still 1.0.18. Phased release remains configured.

## What changed in App Store Connect

- Version 1.0.21 had been waiting for review since 00:15 PDT with build 20260914224229. At the owner's request, that submission (`8f0dfcbb-92b1-4468-9eb5-ccd5b9f432a7`) was cancelled so 1.0.23 could replace it. The cancellation completed at 10:51 and returned the version to `DEVELOPER_REJECTED`.
- The same App Store version was renamed from 1.0.21 to 1.0.23, and build 20260915103231 was attached.
- [What's New](whats-new.txt) now covers everything since the live 1.0.18: OpenCode typography, archive swipe, the one-row composer, neutral controls, and focused new sessions. It read back identical to the local file.
- [Review notes](review-notes.txt) now name 1.0.23, describe the current composer (Files in the + menu, controls after tapping Message), expandable tool rows, and the archive swipe, and summarize changes since 1.0.18. Dated claims about earlier server checks were removed. The notes read back identical to the local file. The demo account remains required, with username `opencode` and the saved password unchanged.

## Verification

| Check | Result |
| --- | --- |
| Build | VALID, APP_STORE_ELIGIBLE, non-exempt encryption false |
| Reviewer access | With the saved App Review credentials, `https://testflight.byot.app` returned 200 for `/global/health` and `/project`. Anonymous requests returned 401. |
| Submission dry run | `wouldSubmit: true`, build already attached |
| Review doctor | One error, about the cancelled 1.0.21 submission no longer containing review items. It did not block the new submission. |
| After submit | Version `WAITING_FOR_REVIEW`; submission `eaf272b2-c8cc-47ce-815d-dd4824c18125` `WAITING_FOR_REVIEW` |

An earlier reviewer-access check reported 401 and was wrong. `asc review details-for-version` returns the demo password as the placeholder `(redacted)` unless `--include-sensitive` is passed, so that check sent the placeholder. The retest with the real saved password passed. A live prompt was not sent through the review server for this submission.

The review stack in `byot/infra/testflight-opencode` on this Mac mini is not what serves `testflight.byot.app`: its `byot-review` Colima profile is stopped, its launchd watchdog is not loaded (last log August 24), and its `.env` login is rejected by the live endpoint. The live endpoint is served elsewhere.

## Identifiers

| Resource | Identifier |
| --- | --- |
| App | `6782403920` |
| App Store version | `e98bbbc9-63a6-46d4-a98a-bfd43371719b` |
| Build | `14e25346-cfae-4ffa-8435-774414c5dbfe` (1.0.23, 20260915103231) |
| Review submission | `eaf272b2-c8cc-47ce-815d-dd4824c18125` |
| Cancelled submission | `8f0dfcbb-92b1-4468-9eb5-ccd5b9f432a7` (1.0.21) |
| Review detail | `206393d3-30b4-4f3c-bc55-6f143c82d272` |
| Source | `c7a475d`, TestFlight receipt `a5a19e0` |
