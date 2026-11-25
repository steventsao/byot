# BYOT Desktop (macOS)

Native SwiftUI + AppKit desktop client for [OpenCode](https://opencode.ai), built as an isolated sibling module to the iOS app so iPhone releases stay completely untouched.

## Architecture (inspired by `anomalyco/opencode`)

OpenCode separates its headless core/client (`packages/core`, `packages/client`, `packages/schema`) from its desktop shell (`packages/desktop`). BYOT mirrors that split natively in Swift:

```text
byot/
├── project.yml            # iOS app, Widgets, ShareExtension, Tests (untouched)
├── Sources/               # iOS UI + pure-Foundation OpenCode engine & stores
├── Shared/                # Shared iOS extension models
└── Desktop/               # Isolated macOS desktop module
    ├── project.yml        # Standalone XcodeGen project (macOS 14+, Swift 6)
    ├── Resources/         # macOS Info.plist, entitlements, AppIcon
    ├── Scripts/           # Local build & signed/notarized DMG packaging
    └── Sources/
        ├── App/           # Window scenes, menus, keyboard commands, app state
        ├── Platform/      # AppKit bridges (SwiftTerm NSView, NSColor palette, core shims)
        └── Views/         # Native macOS NavigationSplitView, transcript, diffs, server setup
```

### Why `Desktop/` keeps iPhone stable

- **Zero changes to iOS:** `Desktop/project.yml` compiles BYOT's pure-Foundation OpenCode layer (`OpenCodeClient`, v1/v2 adapters, SSE event streams, `OpenCodeWorkspaceStore`, `OpenCodeSessionBrowserStore`, `OpenCodeSessionStore`, `OpenCodeDiffReviewStore`, `OpenCodeTerminalStore`, `OpenCodeDiscoveryStore`, `BYOTSyntaxHighlighter`, `KeychainStore`) directly from `../Sources` without editing or moving a single iOS file.
- **Tiny footprint:** No Chromium, no Electron, no embedded Node runtime — just native SwiftUI, AppKit, and `SwiftTerm`.
- **Clean evolution path:** Once Desktop matures, the pure-Foundation files listed under `group: Core` in `Desktop/project.yml` can be extracted into a shared local Swift Package (`Packages/BYOTCore`) consumed by both `project.yml` (iOS) and `Desktop/project.yml` (macOS).

## Build & Run

```bash
cd Desktop
./Scripts/build-desktop.sh --open
```

Or generate the Xcode project manually:

```bash
cd Desktop
xcodegen
open BYOTDesktop.xcodeproj
```

## Packaging a small `.dmg` (direct distribution)

```bash
cd Desktop
./Scripts/package-dmg.sh
```

Set `DEVELOPER_ID_APP` and `NOTARYTOOL_PROFILE` to sign with Hardened Runtime, notarize via `xcrun notarytool`, staple, and produce a compressed `.dmg`.
