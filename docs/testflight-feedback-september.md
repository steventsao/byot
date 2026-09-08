# September 8 tester feedback — 1.0.11

Release base: `91557a0` (1.0.10), including the appearance settings in PR #55 and the earlier navigation, OpenCode 2, attachments, model, and stalled-session fixes.

App Store Connect feedback was fetched on September 8, 2026. The two reports submitted against the latest build, 1.0.10 (20260908143317), are:

- `ABcgbfTZ_z23FVUZPMUnYQM` — restore the horizontal server bar; make projects an optional way to organize sessions instead of a required intermediate screen.
- `AJdDjrxl4r4FFpJ646T_ZBU` — replace generic project icons with useful session status or recency.

The new home screen shows sessions from the selected server, with persisted project grouping and independent Recent activity / Session status / Name sorting for sessions and project groups. Project groups expand in place and show session counts, activity, retry attention, and relative update time. Session rows preserve retry messages and status; status request failures never turn into a false Idle label. The server bar shows the selected server with a checkmark and an accessible selected state. New sessions open their chat immediately and preserve the selected server and directory.

Fetching is bounded to three projects concurrently, publishes each project independently, rejects superseded responses, retains already loaded sessions on a partial refresh failure, and pauses periodic refresh offscreen or when inactive. The existing v1/v2 protocol adapters continue to own their server requests. V1 retains its existing most-recent-100-root-sessions-per-project limit; V2 retains cursor pagination.

Older reports about colors and stalled sessions are covered by the release base and retained regression tests. App Store Connect had no new crash submissions after the July voice reports, which concerned the previous app's removed voice feature.

## Verification

- 162 unit/regression tests passed (68 XCTest tests and 94 Swift Testing tests). Three opt-in live-server tests were skipped because their isolated servers are not running.
- Four UI workflows passed across the final checks: appearance switching/persistence, attachments, session browsing/navigation, and Accessibility XXXL search. The full live-server UI workflow was updated for direct session creation but was not run without its server fixture.
- The browser workflow verifies status/recency, sort ordering, grouping persistence, server isolation on switching, opening a chat directly, and creating a new session directly.
- Store regressions cover progressive loading, partial failures, unknown status, stale refresh rejection, deduplication, archived/child filtering, and sorting.
- Screenshot review prompted stacked headings at Accessibility XXXL and a compact no-results message that remains visible above the keyboard. The UI assertion checks visibility, not just presence.
- Evidence: `/tmp/byot-feedback-20260908/tests-final.xcresult` (all unit tests; initial UI selector mismatch), `browser-navigation.xcresult` (corrected menu selector passes), `browser-accessibility.xcresult` (final accessibility passes), and `tests-second.log` (theme and attachment passes).
- Raw feedback and signed screenshot URLs remain local and are not committed.

## Release

Signed archive and TestFlight distribution pending.
