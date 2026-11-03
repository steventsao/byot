BYOT 1.0.40 — Finished turns fold to their answer, with a timer on every turn

Everything in 1.0.39 is here too. This build changes how a conversation reads: each turn now has a header that times it, a finished turn shows its answer and the files it changed with the steps folded away, and tool calls made back to back share one line.

Please test:

A turn while it runs
• Send a prompt that makes OpenCode read files and run commands. A line under your message says "Working for 5s" and counts up every second. Every step stays in view while it works.
• When OpenCode makes several tool calls in a row, they share one line such as "Read 3 files · Ran 2 commands". The newest of these lines opens by itself so you can watch it; tap it to close or reopen it.

A finished turn
• When the reply ends, the header changes to "Worked for 1m 20s" and the turn folds to its last paragraph, any files or images it produced, and one "Changed N files" list for the whole turn. Tap a file there to open its changes.
• Tap "Worked for …" to see every step again: tool calls, reasoning, retries and the token and cost lines. Tap it again to fold.
• Stop a reply part way with the stop button. Its header says "Stopped after …". A reply that ends in an error says "Failed after …" and still shows the error.
• A reply that only answered, with no tools, shows "Worked for …" with no arrow, since there is nothing to open.

Things that should not change
• Subagent cards stay visible in a folded turn and still open the subagent.
• Commands you run yourself with ! still show as their own terminal card.
• Long-press your own message for Undo and Fork, as before.
• Check in English and in Simplified Chinese.
