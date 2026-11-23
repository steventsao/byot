BYOT 1.0.44 — reading a long reply while OpenCode is still writing it

Everything in 1.0.43 is here too. This build has two fixes and no new features.

Please test:

Scrolling while OpenCode works
• Send a prompt that makes OpenCode run a few commands and write a long answer. While it works, scroll up a little, so you stop just above the newest lines. The app keeps responding: you can scroll, tap and type, and "Jump to latest" appears. In 1.0.43 the app could freeze there.
• Keep scrolling up and down through the reply while it is still being written. Nothing stalls.

Following a turn
• Scroll back down to the end by hand. The screen follows the turn again and "Jump to latest" goes away. In 1.0.43 only "Jump to latest" brought following back.
• At the end, a small nudge of the transcript no longer stops following. Scrolling up into the reply still does.
• Tap "Jump to latest". The screen follows the turn again.

Things that should not change
• While you stay at the end, the screen keeps the newest line in view as tool steps and paragraphs arrive.
• The "Working" indicator, task progress, queued prompts and "Response needed" still appear under the conversation.
• A short conversation that fits on one screen stays under the header.
• Opening a long conversation starts at its latest message.
• Check in English and in Simplified Chinese.
