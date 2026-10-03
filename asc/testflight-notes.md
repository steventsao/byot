BYOT 1.0.32 — optional anonymous usage data

This build adds one thing: byot can send anonymous usage events, and only after you say yes. Everything from 1.0.31 (OpenCode parity: diff review, terminal, shell mode, worktrees, Siri, iPad) is unchanged.

Please test:

The question
• Launch the build with at least one saved server. About 1.5 seconds later a half-sheet asks "Share anonymous usage data?". Tap "Share usage data" or "Not now". It must not ask again on later launches.
• Swipe the sheet away without choosing. That counts as "Not now".
• With no saved server, the sheet must not appear until you add one.

The switch
• About byot (ⓘ) → Privacy → "Share anonymous usage data". Turn it off and on. The footer lists the seven event kinds.
• Check the footer and the sheet in Simplified Chinese (iOS Settings → Apps → byot → Language) and at the largest text size.

What is sent
• Nothing until the switch is on. With it on, send a prompt and let it finish. We expect app_opened, server_connected, session_started, turn_requested and turn_completed in PostHog within a minute, marked as a TestFlight build.
• Nothing in those events may be your server address, project name, prompt or code. If you can, read docs/features/telemetry.md and tell us if any field there feels like too much.

The star ask
• With usage data on or off, finish three turns in one or more sessions. After the third finished turn a card appears above the composer: "Like byot?" with Star byot and Later. Star byot opens github.com/steventsao/byot. Later hides it for 30 days.
• About byot → Support byot has Star byot on GitHub and Rate byot on the App Store.

Also check that Light and Dark Mode look right on the new sheet and card, and that the rest of the app behaves as in 1.0.31.
