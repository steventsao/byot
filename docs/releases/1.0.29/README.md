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

Version 1.0.29, build `20260921121630`. Upload has been committed to App Store Connect; processing and Internal Testers distribution are being verified.
