# BYOT corrected release — Internal TestFlight verified

- Result: **released to Internal TestFlight**. No blockers.
- Version/build/bundle: `1.0.37 / 20261027124118 / com.steventsao.byot`; ASC app `6782403920`.
- Exact source commit: `25a87adbefb79d9ec554dd1316fb89a7ed45d212`. HEAD still equals `/tmp/byot-feedback-20261027/release-source-commit.txt`; `git status --porcelain` is empty. Manifest names that commit.
- Build UUID: `043bf0e4-4202-4a63-973d-590bf9a063b3` (also the uploaded-binary record UUID).
- Archive: `/Volumes/ext-t7/byot-feedback-20261027/Archive-20261027124118/BYOT.xcarchive`.
- IPA: `/Volumes/ext-t7/byot-feedback-20261027/Archive-20261027124118/BYOT.ipa` (11074543 bytes).
- **IPA SHA256:** `d95eb5a024559ffc684ca992b6a0a72bf0cb38a77f337420282afd31125b7f08`. Rehashed unchanged at final verification.

## Signing and packaging

- Signed archive and export succeeded through the normal xcodebuild shim, using Xcode 26.5 (17F42).
- `codesign --verify --deep --strict`: PASS. Certificate SHA1 `1D462C7D89B2F934CDB8255C2533A44BF02745DF` matches the required identity.
- Profile: `BYOT Queue App Store 20260920`; UUID `c24d9c62-70c2-4e42-9c1c-8ef665ec9fa2`; expiry `2027-06-09T16:51:22Z`.
- Signed app identifier `449BD89VDV.com.steventsao.byot`; production push entitlement; get-task-allow=false.
- Mandatory IPA privacy gate: PASS for `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`, `NSMicrophoneUsageDescription`, and `NSSpeechRecognitionUsageDescription`. Every base key has readable, nonempty en.lproj and zh-Hans.lproj values; no raw-key values; each English value exactly equals its base Info.plist explanation.
- Apple pre-upload validation: PASS (`validated: true`, VERIFY SUCCEEDED with no errors).

## Upload and distribution

- Exactly **one** `asc publish testflight --ipa` upload attempt, completed successfully. No second upload, rebuild, or build-ID recovery upload was needed.
- ASC uploaded-file receipt: `BYOT.ipa`, delivery COMPLETE, size 11074543 bytes, MD5 `C5003304349096B747122D905E595275`, matching the exact local IPA.
- Uploaded-binary processing: **COMPLETE**, zero reported warnings/errors, including no warning 90738.
- Build processing: **VALID**. Internal state: **IN_BETA_TESTING**.
- Group membership: complete lookup confirms exactly one group, **Internal Testers** (`a2c29c92-ddfd-4c22-9368-8563d9b756ea`), internal and explicitly assigned.
- en-US What to Test notes byte-match `asc/testflight-notes.md`: **1697 bytes**, SHA256 `4431f2227519da0d68af006eba1e2e60a39682b0d14f9174b2e0521cfc4b48ec`. The publisher and notes-update CLI trimmed the trailing newline; a scoped PATCH of this build's existing notes localization restored the exact text. The API response and subsequent CLI fetch verify the byte match.
- Final `asc validate testflight --app 6782403920 --build-id 043bf0e4-4202-4a63-973d-590bf9a063b3`: PASS; errors=0, warnings=0, blocking=0 (rerun after the exact-notes correction).
- No App Store review or external beta review submission. External state remains READY_FOR_BETA_SUBMISSION. No --notify or --submit flag was used.

## Elapsed status

- Archive/export/Apple validation: 458.8 seconds (2026-10-27T19:59:01.263312+00:00 to 2026-10-27T20:06:40.063046+00:00).
- Single upload, discovery, and distribution command: 937.57 seconds (2026-10-27T20:07:33.276462+00:00 to 2026-10-27T20:23:10.844116+00:00).
- Total from wrapper start through final verification: 1604.05 seconds. Final verification: 2026-10-27T20:25:45.317842+00:00.
- Previous candidate `20261027115114`, its `Archive/` folder and logs were preserved. It was not uploaded or distributed by this run.
- No source edits, commits, pushes, tags, remote changes, agents, or simulator operations.

## Receipts

Sanitized CLI/API receipts are saved under both `/Users/steventsao/dev/byot-ios-feedback-20261027/.asc/artifacts/` and `/tmp/byot-feedback-20261027/`:
- Parent manifest: `/Users/steventsao/dev/byot-ios-feedback-20261027/.asc/artifacts/release-manifest-1.0.37-20261027124118.json`.
- `archive-wrapper-1.0.37-20261027124118.json`
- `artifact-verification-1.0.37-20261027124118.json`
- `publish-status-1.0.37-20261027124118.json`
- `publish-receipt-1.0.37-20261027124118.json`
- `uploaded-binary-files-1.0.37-20261027124118.json`
- `final-upload-1.0.37-20261027124118.json`
- `final-build-1.0.37-20261027124118.json`
- `final-build-app-1.0.37-20261027124118.json`
- `final-beta-detail-1.0.37-20261027124118.json`
- `final-groups-1.0.37-20261027124118.json`
- `final-test-notes-1.0.37-20261027124118.json`
- `notes-exact-api-update-1.0.37-20261027124118.json`
- `notes-byte-verification-1.0.37-20261027124118.json`
- `testflight-validation-1.0.37-20261027124118.json`
- `final-verification-1.0.37-20261027124118.json`

Archive log: `/tmp/byot-feedback-20261027/archive-corrected.log`; sanitized copy `/Users/steventsao/dev/byot-ios-feedback-20261027/.asc/artifacts/archive-corrected-1.0.37-20261027124118.log`.
Upload log: `/tmp/byot-feedback-20261027/publish-1.0.37-20261027124118.log`, also copied to `/Users/steventsao/dev/byot-ios-feedback-20261027/.asc/artifacts/publish-1.0.37-20261027124118.log`.
Archive run receipt: `archive-corrected-run.json` in both directories.
Pre-upload duplicate checks and timestamped processing checks are also retained in both directories.
