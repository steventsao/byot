# App Store preparation — BYOT 1.0.32

Staged on 2026-10-03 from the Mac Mini with the `asc` CLI. **Not submitted.**

| Item | Value |
| --- | --- |
| App Store version | `2093b55e-a285-4cde-9a50-b884446fc005` — 1.0.32, `PREPARE_FOR_SUBMISSION` ([version-create.json](version-create.json)) |
| Build | `69acd17b-dc67-4ae5-930d-0a624bdd4782` — 1.0.32 (20261003162138), processing `VALID`, attached ([attached-build.json](attached-build.json)); the same build is on TestFlight for Internal Testers |
| Metadata | Copied from live 1.0.31, then the en-US description and What's New replaced from [description.txt](description.txt) and [whats-new.txt](whats-new.txt); the "no analytics" sentence is gone ([localization-update.json](localization-update.json)) |
| Review notes | Updated from [review-notes.txt](review-notes.txt) (3,904 characters; the limit is 4,000). Contact and demo account carried over from 1.0.31 unchanged ([review-detail.json](review-detail.json)) |
| Readiness | `asc review doctor`: 0 errors, 0 warnings, 0 blocking ([review-doctor.txt](review-doctor.txt)) |

## Before submission

1. **App Privacy label.** Add the four Analytics rows from [privacy-disclosures.md](privacy-disclosures.md) (Product Interaction, Other Diagnostic Data, Device ID, Coarse Location: not linked, no tracking) next to 1.0.31's relay rows. This needs the App Store Connect website; the API cannot edit it.
2. **Site copy.** `cd web && npm run deploy`, so byot.app and byot.app/privacy stop saying "No analytics" when the build goes live. The branch already holds the new copy.

## Submit

From the Mini (`ssh mini`, the box with working `asc` credentials):

```sh
asc review submit --app 6782403920 --version-id 2093b55e-a285-4cde-9a50-b884446fc005 --build-id 69acd17b-dc67-4ae5-930d-0a624bdd4782 --confirm
```
