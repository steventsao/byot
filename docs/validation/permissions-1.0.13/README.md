# App Store 1.0.13 permission UI acceptance

Verified September 9, 2026 on Steven's Mac mini. **The native permission card renders and all three choices work against the real OpenCode 2 server.**

App source: `app-store/1.0.13`, commit `f81c49ebcb337243f09a62498edb4093d8c101c5`. Production source and project configuration are unchanged. The simulator app was rebuilt from that source with the new UI test target; this is not the downloaded App Store binary.

Environment: OpenCode 2 `0.0.0-beta-19271`, iPhone 17 Pro simulator, iOS 26.5 (23F77), normal signed app, HTTPS transport and Keychain. A fresh isolated server/project had shell permissions set to ask. Existing OpenCode servers and YOLO configuration were not changed.

## Results

One focused UI workflow passed, zero failures and zero skips:

| Check | Result |
| --- | --- |
| Server emits pending request; app displays permission name and command | Passed |
| Reject, Allow once and Always allow visible and tappable | Passed |
| Allow once replies `once`; server removes pending request | Passed, HTTP 204 |
| Repeating that command still requires approval | Passed |
| Reject replies `reject`; server removes pending request | Passed, HTTP 204 |
| Repeating a rejected request still asks | Passed |
| Always allow shows its scope confirmation | Passed |
| Dismissing confirmation leaves the request pending | Passed |
| Confirm sends `always`; repeated matching request evaluates to allow | Passed, HTTP 204 and server rule verification |
| No reusable scope hides Always allow and explains why | Passed |

The initial test driver tried to tap a separate Cancel button. iOS 26 presents the confirmation as a popover; tapping outside dismisses it. The driver was corrected and the complete workflow rerun successfully. No production fix was necessary.

## Scope

Permission requests were created through the real upstream `/api/session/{id}/permission` API in the isolated session. They were not mocked in the app or emitted by an AI model. Sample `printf` commands were permission resource strings; no shell commands were executed. This verifies native rendering, live request refresh, UI actions, HTTP replies and reusable-rule evaluation. It does not establish model-to-tool continuation, persistence across server restart, physical-device behavior or Tailscale connectivity.

## Evidence

- [Permission card](permission-card-allow-once.png)
- [Always allow confirmation](permission-always-confirmation.png)
- [No reusable scope](permission-no-reusable-scope.png)
- [XCTest summary](summary.json)
- [Server-observed replies](permission-replies.jsonl)
- [Environment, result location and original screenshot checksums](evidence.json)
- Full passing bundle: `/tmp/byot-upstream-e2e.p98Tv3/tests.xcresult`

Run again from this test branch:

```sh
BYOT_E2E_ONLY_TESTING=BYOTUITests/OpenCodePermissionLiveUITests scripts/test-opencode-upstream.sh
```

The runner removes its owned simulator and server processes after completion and retains evidence in its printed temporary directory.
