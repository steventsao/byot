# BYOT 1.0.29 — empty session screen alignment

Addresses TestFlight feedback `AHDMiKT6k_HpVW45LJ2zTHU` on 1.0.28: “Session loading screen words misaligned.” The attached screenshot shows the empty-session action rendering “New session” one character per line. The earlier report `AL5ZLFDrP5s2cxxhF8izJ2M` shows the same problem.

The empty state now has a native bordered text button with an intrinsic-width title and a minimum 44-point touch target. It opens the same new-session screen. The separate bottom compose icon is unchanged. This release is based on the shipped 1.0.28 source, preserving its draft persistence, foreground reconciliation, notifications, and durable queue support.

## Validation

- Reproduced the original bug with the empty-server fixture: the button measured 48 × 208.33 points. See [baseline result](before-ui-summary.json) and [before screenshot](before-empty-sessions.png).
- The final full unit suite and two focused UI regressions passed: 248 tests, zero failures, eight existing opt-in live-server tests skipped. See [results](tests.json).
- Both default and Accessibility XXXL checks verify horizontal layout, a 44-point touch target, screen bounds, clearance above search, and navigation into the new-session screen. Screenshots were visually reviewed: [default text](empty-sessions.png), [largest text](empty-sessions-largest-text.png).
- The existing bottom-compose flow also passed its server/project selection and keyboard-focus check during the first regression run.
- UI validation used iOS 26.3.1 in Dark Mode. The reporting device runs iOS 27; no iOS 27 simulator was available locally. Live-server and physical-device APNs tests were not rerun for this layout-only change.
- The signed archive was built with Xcode 26.5 on the existing release Mac. Local and release-Mac Sources hashes match (`6d7280e7f579e6e318c6a42cc4fe1d5cd043a5e5644f4dfd30bf0956aa3880d0`). The final IPA has a verified distribution signature, production APNs entitlement, and `get-task-allow=false`. See [signature receipt](signature-receipt.json).

## Distribution

**Available to Internal Testers:** 1.0.29 (`20260921121630`), build `cb22a475-43e2-4306-af55-01265d45550a`. Independent App Store Connect reads confirm `VALID`, `IN_BETA_TESTING`, Internal Testers membership, and matching test notes. See [verification](release-verification.json) and [publish receipt](testflight-publish.json).

The shipped source is commit `95bc946`. The final IPA is retained locally at `.asc/artifacts/BYOT-1.0.29.ipa`; the signed archive is on the release Mac at `/Users/steventsao/dev/byot-testflight-loading-1.0.29/.asc/artifacts/BYOT.xcarchive`.

The separate `altool --validate-app` check completed after the upload and returned Apple's duplicate-build error 90189. No second upload was attempted. The uploaded binary subsequently processed successfully to `VALID` and entered internal beta testing.
