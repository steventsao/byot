# App Store screenshots

Rendered from the current app, not composited. `OpenCodeAppStoreScreenshotHarness`
(DEBUG only, `--app-store-screenshots`) runs the production browser, session,
composer, permission, question, and diff views against a deterministic OpenCode
v1 fixture served through `URLProtocol`. No server, account, or user data is
involved. `AppStoreScreenshotUITests` walks one session through its phases and
attaches each frame. The README gallery uses the iPhone set.

| # | File | Shows |
| --- | --- | --- |
| 1 | `01-sessions.png` | Session browser: two servers, sessions across projects, live Working and Idle status |
| 2 | `02-live-turn.png` | Streaming turn: reasoning, search, read, write, and a running edit, with task progress |
| 3 | `03-answer-questions.png` | Question card with three strategies and a custom answer |
| 4 | `04-approve-permissions.png` | Bash permission request: Allow once, Always allow, Reject |
| 5 | `05-turn-complete.png` | Finished turn: tests pass, summary of the changed files |
| 6 | `06-review-changes.png` | Session changes with expanded unified diffs |

| Directory | Pixels | App Store Connect display type | Simulator |
| --- | --- | --- | --- |
| `screenshots/en-US/iphone-6.9/` | 1320 × 2868 | `APP_IPHONE_67` | iPhone 17 Pro Max |
| `screenshots/en-US/ipad-13/` | 2064 × 2752 | `APP_IPAD_PRO_3GEN_129` | iPad Pro 13-inch (M5) |
| `screenshots/en-US/ipad-12.9/` | 2048 × 2732 | `APP_IPAD_PRO_129` | iPad Pro (12.9-inch) (6th generation) |

The app is universal, so App Store Connect needs an iPad set as well as the
iPhone set. The two iPad slots reject each other's dimensions, so both are kept.

## Reshooting

```bash
scripts/capture-app-store-screenshots.sh              # every set
scripts/capture-app-store-screenshots.sh iphone-6.9   # one set
```

Each set gets a fresh simulator with a 9:41 status bar, full battery, and Dark
appearance (`BYOT_SCREENSHOT_APPEARANCE=light` to change it). The script fails
if any frame is not the exact App Store size. To change what a frame shows,
edit the fixture in `Sources/OpenCodeAppStoreScreenshotHarness.swift`.
