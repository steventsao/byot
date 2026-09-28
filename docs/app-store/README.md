# App Store screenshots

Rendered from the current app, not composited. `OpenCodeAppStoreScreenshotHarness`
(DEBUG only, `--app-store-screenshots`) runs the production browser, session,
composer, shell, permission, usage, and diff views against a deterministic
OpenCode v1 fixture served through `URLProtocol`; the terminal frame uses
`OpenCodeTerminalHarness` with the same flag. No server, account, or user data
is involved. `AppStoreScreenshotUITests` walks one session through its phases
and attaches each frame. The README shows four iPhone frames, downscaled into
`docs/screenshots/readme/`.

| # | File | Shows |
| --- | --- | --- |
| 1 | `01-live-turn.png` | Streaming turn: tool calls, highlighted TypeScript, task progress, context meter |
| 2 | `02-shell-mode.png` | Shell mode: a `!` command in the composer, a `git status` run in the transcript |
| 3 | `03-review-changes.png` | Colored, wrapped diff of one changed file |
| 4 | `04-approve-permissions.png` | Bash permission request: Allow once, Always allow, Reject |
| 5 | `05-terminal.png` | Terminal tabs: `git log` and a passing test run |
| 6 | `06-context-usage.png` | Context and usage sheet: window use, model, cost, tokens |
| 7 | `07-sessions.png` | Session list across projects with live Working and Idle status (iPhone only) |
| 8 | `08-server-setup.png` | First run: scan a pairing code, find nearby, or add a server (iPhone only) |

On iPad every frame already shows the session list beside the conversation, so
the set stops at frame 6.

| Directory | Pixels | App Store Connect display type | Simulator |
| --- | --- | --- | --- |
| `screenshots/en-US/iphone-6.9/` | 1320 × 2868 | `APP_IPHONE_67` | iPhone 17 Pro Max |
| `screenshots/en-US/ipad-13/` | 2064 × 2752 | `APP_IPAD_PRO_3GEN_129` | iPad Pro 13-inch (M5) |

The app is universal, so App Store Connect needs an iPad set as well as the
iPhone set. `scripts/capture-app-store-screenshots.sh ipad-12.9` still renders
the 2048 × 2732 set for the older 12.9-inch slot if it is ever needed.

## Reshooting

```bash
scripts/capture-app-store-screenshots.sh                        # every set
scripts/capture-app-store-screenshots.sh iphone-6.9 ipad-13     # the committed sets
```

Each set gets a fresh simulator with a 9:41 status bar, full battery, and Dark
appearance (`BYOT_SCREENSHOT_APPEARANCE=light` to change it). The script fails
if any frame is not the exact App Store size. To change what a frame shows,
edit the fixture in `Sources/OpenCodeAppStoreScreenshotHarness.swift`.
