# App Store preparation — BYOT 1.0.29

App Store version `99f0c629-0f16-4d03-9909-11848d68d483` is prepared with the existing description/keywords/screenshots as a starting point. The updated description and What's New cover everything since live 1.0.23, including saved drafts, optional notifications and computer queues, import limits, foreground reconciliation, and empty-state alignment. The three iPhone/iPad screenshot sets were retained. Release remains MANUAL, matching the existing policy.

Review notes describe the current flow and optional companion, retain the secure demo-account password and contact fields, and use `/workspace` with `opencode/big-pickle`. All text was read back and matched the local files. Reviewer credentials returned 200 for health, projects, and providers; anonymous access returned 401. A fresh scratch session answered the exact verification prompt, and the verification session was archived afterward. See the access and live-review receipts.

## Corrected privacy manifest

The relay stores a device token and associates delivery/queue records with its subscription. The four already-declared data categories are now correctly marked linked to the user/device, for App Functionality only and never tracking. No data collection or runtime code changed. See [privacy disclosures](privacy-disclosures.md) for the matching App Store label values and rationale.

Replacement build: **1.0.29 (`20260921123203`)**. The archive was rebuilt with the corrected manifest; strict code-signature verification and comparison of the embedded manifest passed. Swift sources remain identical to tested source `95bc946` (246 unit tests and two focused UI tests passed for that source). See [signature receipt](signature-receipt.json).

## Submission status

**Not yet submitted.** The published App Privacy label currently says Data Not Collected and must be updated. Apple web authentication has expired on both available Macs, and API credentials cannot edit that label. An App Store Connect browser sign-in has been requested from the owner.

The standard readiness check reports zero errors and zero warnings; the submission dry run returns `wouldSubmit: true`. The extra URL checker warns only that `https://byot.app` is the marketing site root, which is the intended product landing page. Support and privacy URLs resolve correctly, and fresh direct reads confirm they include notifications, encrypted queue handling, and retention. Apple web privacy publication still requires verification before the final submit.

The replacement archive is undergoing Apple validation; after processing, attach it to this version, update/publish the App Privacy labels, and run the final review submission.
