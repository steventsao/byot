# App Store preparation — BYOT 1.0.32

Staged and **submitted for review on 2026-10-03 (17:05 PDT)** from the Mac Mini with the `asc` CLI. Submission `161b7bc6-a7c3-4118-8cd6-ee4b96dbf235`, state `WAITING_FOR_REVIEW` ([review-submit.json](review-submit.json)). The App Privacy label was updated 40 minutes after submission, with `asc web privacy` (see below).

| Item | Value |
| --- | --- |
| App Store version | `2093b55e-a285-4cde-9a50-b884446fc005` — 1.0.32, `PREPARE_FOR_SUBMISSION` ([version-create.json](version-create.json)) |
| Build | `411a9060-16b5-4c42-8129-47644e29987f` — 1.0.32 (20261003165115), processing `VALID`, attached ([attached-build.json](attached-build.json)); the same build is on TestFlight for Internal Testers |
| Metadata | Copied from live 1.0.31, then the en-US description and What's New replaced from [description.txt](description.txt) and [whats-new.txt](whats-new.txt); the "no analytics" sentence is gone ([localization-update.json](localization-update.json)) |
| Review notes | Updated from [review-notes.txt](review-notes.txt) (3,904 characters; the limit is 4,000). Contact and demo account carried over from 1.0.31 unchanged ([review-detail.json](review-detail.json)) |
| Readiness | `asc review doctor`: 0 errors, 0 warnings, 0 blocking ([review-doctor.txt](review-doctor.txt)) |

## App Privacy label (done 2026-10-03, 17:45 PDT)

`asc web privacy pull` → add four rows → `plan` (4 adds, 0 deletes) → `apply` → `publish --confirm` → `pull` to verify. The label now has eight rows: 1.0.31's four relay rows (App Functionality, linked) plus Product Interaction, Other Diagnostic Data, Device ID and Coarse Location (Analytics, **not linked**, no tracking). Receipts: [privacy-declaration.json](privacy-declaration.json), [privacy-plan.json](privacy-plan.json), [privacy-apply.json](privacy-apply.json), [privacy-publish.json](privacy-publish.json), [privacy-after.json](privacy-after.json). Rationale: [privacy-disclosures.md](privacy-disclosures.md).

## Owner follow-up

1. **Site copy.** `cd web && npm run deploy` when the version goes live, so byot.app and byot.app/privacy stop saying "No analytics". The branch already holds the new copy.
2. **Open the PR** for `feat/usage-telemetry` (the session's `gh` token was invalid).

## Submitted with

```sh
asc review submit --app 6782403920 --version-id 2093b55e-a285-4cde-9a50-b884446fc005 --build-id 411a9060-16b5-4c42-8129-47644e29987f --confirm
```
