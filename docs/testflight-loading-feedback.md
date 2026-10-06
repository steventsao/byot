# TestFlight slow-connection rendering

This work was written on September 28, 2026 and shipped in [1.0.33](releases/1.0.33.md). The validation below is from that date; the 1.0.33 record has the current results.

Feedback `AKWY7o8vHhCEjrJIhzCg0sM`, submitted September 24, 2026 PDT on
1.0.30 (`20260924002512`), shows completed task progress floating above an empty
transcript loader and a second spinner in the composer. The implementation is
based on the current iOS repository after the 1.0.31 release.

The session refresh previously awaited messages, permissions, questions, diffs,
and status together before publishing any messages. Task metadata loads
separately, so it could appear while downloaded messages were still withheld.
The transcript now publishes as soon as its own request completes. Status still
controls prompt submission, and generation checks preserve newer refreshes and
streamed updates. A failed transcript request exposes its error immediately,
and leaving the session clears loading state without applying late results.

An empty transcript now has one loader centered in the conversation viewport.
Task progress and turn activity wait until that placeholder has cleared; cached
messages, local messages and actionable permission requests remain visible.
The composer omits its duplicate progress indicator while the transcript loads,
and the header no longer reports Idle before status has been confirmed.

Earlier feedback `AHDMiKT6k_HpVW45LJ2zTHU` (the vertical “New session” label) was
already fixed in 1.0.29. Its largest-text UI regression is included in validation
for this change.

Validation on September 28, 2026 used an iPhone 17 simulator, iOS 26.5, and Xcode
26.5. The reporting device runs iOS 27; that runtime was not available locally.

- All 702 unit tests passed; eight existing opt-in live-server tests were skipped.
  The five new tests cover delayed status, early transcript failure, superseded
  snapshots, leaving during loading, and preserving messages during refresh.
- The existing largest-text empty-session alignment check passed.
- Both new UI regressions passed with a 15-second transcript delay and immediate
  task metadata. They verify one centered loader, no premature task row, no
  duplicate composer spinner, disabled empty submission, and transition to the
  loaded transcript. Screenshots were visually reviewed at
  [normal text](testflight-loading-feedback/slow-transcript.png) and
  [Accessibility XXXL](testflight-loading-feedback/slow-transcript-largest-text.png).
- The [full run](testflight-loading-feedback/full-suite-run.json) had one UI
  fixture failure: the target session was offscreen in the largest-text list.
  The fixture now contains only that session. The [final focused run](testflight-loading-feedback/focused-tests.json)
  passed all five loading tests and both UI regressions. Application code was
  unchanged between these runs.
- `git diff --check` passed. No TestFlight upload or version bump was performed.

The first run exhausted local disk space during screenshot capture. This run's
temporary compiler/index data and result bundles were moved to
`/Volumes/T7-Warm/byot-feedback-20260928`, and the measured 372 MiB npm cache was
cleared. The uv cache was in use, so its cleanup was canceled. Available internal
disk space recovered from 119 MiB to 1.9 GiB after testing; source repositories,
simulator data, signing credentials, and release artifacts were preserved.
