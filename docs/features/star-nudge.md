# Star and review ask

After a turn that byot requested finishes well, byot may ask for one thing.
The code is `Sources/BYOTNudge.swift` (the gate) and
`Sources/BYOTNudgeCard.swift` (the card); the conversation screen mounts the
card above the composer.

## Rules

| Rule | Value |
| --- | --- |
| Value moment | `turn_completed` with `result = completed`, conversation still open |
| First ask | the third completed turn on this device |
| Cooldown | 6 days from any ask, answered or not |
| Later | cooldown, and the turn bar doubles (3 → 6 → 12 …) |
| Star byot | opens github.com/steventsao/byot; byot cannot see the star, so opening counts |
| After a star | the ask becomes Apple's `requestReview()`; Apple shows it at most three times a year |
| Never | unit tests, UI fixtures (`BYOTLaunch.isAutomated`) |

About byot → Support byot has the same two actions as plain rows: "Star byot
on GitHub" (also counts as starred) and "Rate byot on the App Store", which
opens the App Store review page.

## Why this shape

Orca's desktop app runs a star card with a threshold, a 3-day cooldown and a
doubled threshold on dismiss, and never asks once the repo is starred. BYOT
copies that, with six days instead of three, because a phone client sees
fewer sessions a day. Apple's guidelines allow a custom card for a GitHub
star but not for a review, so the review half is Apple's own prompt.

## Telemetry

When usage data is on, the ask records `nudge_outcome` with `kind`
(`star_card` / `review_request`), `outcome` (`shown` / `starred` / `later` /
`requested`), `completed_turns` and `threshold`. See
[telemetry.md](telemetry.md).
