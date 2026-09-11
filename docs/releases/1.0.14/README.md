# BYOT 1.0.14 — reliability and accessibility

GitHub milestone: [TestFlight: reliable model recovery and accessible controls](https://github.com/steventsao/byot/milestone/3).

This release addresses #44, #45, #46, #48, and #50. It starts from main `ed39923` and includes the already distributed appearance and session-browser changes from #55/#56 plus the connection service refactor in #57.

## Behavior

- **#44:** Provider error envelopes display their human-readable detail. An unavailable model offers **Choose another model** in the conversation. After an explicit selection, **Retry last message** resends the original text and embedded attachments with a new admission ID. Busy turns, duplicate taps, and turns with assistant output or tool calls cannot use this replay action. Existing unanswered-turn recovery and queued-message behavior remain separate.
- **#48:** At accessibility text sizes, attachment chips use a bounded vertical list. Filenames truncate and removal has a visible target of at least 44 × 44 points.
- **#50:** The Automatic model row and loading/empty/error states share the list's scroll layout; no empty-state overlay covers selectable rows.
- **#45:** The shipped session browser uses the generic **No matching sessions** state. Its regression now uses the reported 139-character query at Accessibility XXXL.
- **#46:** The shipped adaptive surfaces and System/Light/Dark settings are retained. Contrast tests cover primary text on all shared surfaces and primary controls in both modes.

## Upstream contract

Live acceptance uses pinned OpenCode **1.18.29** and **2 beta 19271**, production HTTPS and Keychain code, and a deterministic local provider. Each server also has a separate `retired` project whose default model returns HTTP 410. The UI must encounter that failure through Automatic, choose the working model, and receive a response to the retried prompt.

The beta's actual failed assistant projection contains `error: {type: "provider.invalid-request", message: "Provider request failed with HTTP 410", status: 410}`. It omits the provider's response body. BYOT preserves the typed error and status through snapshot and event normalization to offer recovery in this case too.

## Verification and distribution

Work in progress. The milestone remains open until the final regression and UI results, release archive validation, and Internal Testers distribution are recorded here.

No physical-device validation is claimed.
