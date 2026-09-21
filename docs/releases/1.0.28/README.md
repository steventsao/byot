# BYOT 1.0.28 — drafts and session reliability

Based on the shipped 1.0.27 durable-queue release. Unsent composer text, attachments, and remote file selections now persist locally per server, session, directory, and workspace. Draft files use iOS complete file protection and are excluded from backups. Attachment bytes are saved only when the selection changes. A storage failure is visible in the composer; a rejected submission keeps its original draft.

Send is disabled while photos or files are importing, including keyboard submission. File count is checked before loading and total bytes after each import, preventing an oversized multi-file selection from accumulating unchecked. Returning to the foreground schedules reconciliation without cancelling or repeating prompt submissions.

## Validation

The full unit suite passed: 246 tests, zero failures; eight existing live-server opt-in tests skipped. New tests cover full draft restoration/clearing, isolation across contexts, write failures, preserving attachment bytes while editing text, and foreground status reconciliation without aborting or sending a prompt. Both durable-queue UI regressions passed before the simulator automation stalled. See [unit and queue evidence](unit-and-queue-tests.json).

The release Mac initially stalled inside its shared SwiftPM cache before compilation. The existing release script's isolated-cache mode resolved that host issue. The archive uses the existing distribution identity and App Store profile; no certificate was replaced or revoked. Local and remote Swift source hashes match.

Physical-device APNs delivery and the eight live-server opt-in tests were not re-run for this client-only change.

Five focused UI checks passed on iOS 26.5: draft termination/restoration/clearing, attachment touch targets at the largest text size, server-file sheet dismissal and composer collapse, the large-text model picker, and image/document previews. Screenshots were visually reviewed. See [UI results](focused-ui-tests.json), [restored draft](restored-draft.png), [image preview](image-preview.png), and [large-text picker](model-picker-accessibility.png).

The earlier iOS 26.3 run passed seven of eleven UI tests but reported four failures: a 44 pt button measured as 43.99999999999994 pt, file-sheet dismissal, revealing the model picker, and the image-preview wait. The test now uses a 0.01 pt measurement tolerance and targets Done inside the file browser navigation bar. All four checks passed in the focused release-Mac run. Local diagnostic collection stalled; those results are retained in the terminal log rather than represented as a completed result bundle. Application code did not change after upload.

## Distribution

**Available to Internal Testers:** 1.0.28 (`20260920235124`), build `0800d0e3-29d3-4ed9-8bac-55ad99de7dfd`. Independent App Store Connect reads confirm `VALID`, `IN_BETA_TESTING`, membership in Internal Testers, and test-note content. See [verification](release-verification.json), [signature](signature-receipt.json), [Apple validation](apple-validation.txt), and [publish receipt](testflight-publish.json).

The shipped application source is commit `6a42553`. Later changes only tighten UI test assertions and record release evidence. The IPA is retained at `.asc/artifacts/BYOT-1.0.28.ipa`; the signed archive remains on the release Mac at `/Users/steventsao/dev/byot-testflight-readiness-1.0.28/.asc/artifacts/BYOT.xcarchive`.
