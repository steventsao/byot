# Appearance settings — 1.0.10

The home screen's information button now opens an Appearance picker with System, Light, and Dark. System is the default. The selection is stored locally and takes effect immediately across the app and presented sheets.

The preference is applied to the app's own window using [UIKit's appearance override](https://developer.apple.com/documentation/uikit/uiview/overrideuserinterfacestyle). System restores `.unspecified`, allowing subsequent device appearance changes to flow through. The bridge handles both initial window attachment and later preference changes without rebuilding navigation or session state.

During UI verification, resetting SwiftUI's `preferredColorScheme` to `nil` left the open settings sheet light on a dark-mode device. The window implementation passes that rendered-color regression check.

## Verification

- Final full suite: 156 tests passed, zero failures, four opt-in live-server tests skipped. Parameterized cases account for 163 passing executions in the device summary.
- Simulator: iPhone 17 Pro, iOS 26.5; Xcode 26.5.
- UI checks cover the initial System choice, Light and Dark rendering in About/home/server forms, persistence after relaunch, and returning to System while a sheet is open.
- Dark-system result: `/tmp/byot-theme-window-dark.xcresult`.
- The appearance UI workflow also passed with the device in light mode: `/tmp/byot-theme-window-light.xcresult`.
- With System saved, toggling the simulator light → dark → light while BYOT remained open produced white → black → white backgrounds, without relaunch. Screenshots: `/tmp/byot-theme-live-system/`.
- Release artifacts: `/tmp/byot-release-1.0.10/`.

The signed archive and exported IPA both report `com.steventsao.byot`, version `1.0.10`, build `20260908143317`. Apple validation passed with no errors (`build-final.log`).

Device installation through TestFlight is not part of the simulator verification.

## Internal TestFlight release

- Published September 8, 2026: **1.0.10 (20260908143317)**.
- Build ID: `1ca2ddb7-20ef-4f89-a76d-876e71989c4b`.
- Processing state: `VALID`; internal state: `IN_BETA_TESTING`.
- Explicit membership confirmed in **Internal Testers** (`a2c29c92-ddfd-4c22-9368-8563d9b756ea`).
- English What to Test notes match `asc/testflight-notes.md`.
- Release source: `a16d992`; draft PR: <https://github.com/steventsao/byot/pull/55>.
- Upload and confirmation logs: `/tmp/byot-release-1.0.10/publish.log`, `build-info.json`, and `test-notes.json`.
