BYOT 1.0.42 — small polish: session names, prompt menu, haptics

Everything in 1.0.41 is here too. This build has three small changes and no new features.

Please test:

Session names
• Create a session and go back to the list before sending anything. It is listed as "New session", not "New session - 2026-…" with a timestamp. The time it was updated is still on the row.
• Send a prompt. Once OpenCode names the session, the list shows that name.

Long-press on your prompt
• Long-press the words of a prompt you sent. The menu has Select text, Copy prompt, Undo to this prompt and Fork before this prompt.
• Copy prompt puts only what you typed on the clipboard.
• Long-press a reply. Its menu still says Copy response.

Haptics
• Sending a prompt gives a light tap.
• When OpenCode asks for a permission or an answer while the session is open, the phone gives a warning buzz.
• When a turn finishes while the session is open, the phone gives a soft tap.

Things that should not change
• The session screen, the composer and the Worktrees screen look and behave as in 1.0.41. Their code was rearranged so the app builds on an older Xcode.
• Check in English and in Simplified Chinese.
