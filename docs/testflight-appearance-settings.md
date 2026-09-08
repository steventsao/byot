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
