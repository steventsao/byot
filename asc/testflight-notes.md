BYOT 1.0.31 — OpenCode parity

This release brings most of what OpenCode's terminal and web app can do to iPhone and iPad. byot shows a feature only when your OpenCode server supports it, so a missing button usually means the server doesn't offer that feature.

Please test, by area:

Conversations
• Replies stream live on OpenCode 1.x and the v2 beta. Code is syntax colored, Markdown tables show as grids, and images appear inline.
• Session menu → Context and usage: the context window, plus tokens and cost for each reply and for the session.
• Tap a subagent's task card to open its session.
• Session menu: Export transcript, Copy all, Set up AGENTS.md, and Publish on web (share or unpublish the link).

Composer
• Tap the agent button to switch between Build and Plan.
• Type ! in an empty composer to run a shell command on the server.
• Tap the microphone to dictate.

Changes and terminal
• Review changes: a colored diff for each file, for the whole session or for one turn.
• Terminal (toolbar): a live shell on your computer. Try a long-running command, rotate the phone, and close tabs.

Sessions and servers
• The session list updates on its own as sessions start, finish or need you.
• Status (toolbar): branch, MCP and LSP status, and configuration. Server settings changes the default model, agent, sharing and more, and asks before saving.
• New session → Worktree: start a session in its own worktree. Worktrees can also be reset or deleted.
• With Airplane Mode on, recent sessions and transcripts stay readable and are marked as saved.
• Add server → Scan pairing code (run scripts/byot-pair-qr.sh on your computer), or choose a server from Find nearby.

Outside the app
• Approval notifications: choose Allow once or Reject right from the notification.
• Live Activity and Dynamic Island while a turn runs, plus Home Screen and Lock Screen widgets for sessions that need you.
• Siri and Shortcuts: "Ask OpenCode in byot", "What needs me in byot".
• Share a link, photo or file to byot from another app.
• iPad: sessions sit beside the conversation. With a keyboard, try ⌘N, ⌘K, ⌘[ and ⌘], ⌘↩ and ⌘. (period).
• Simplified Chinese: change byot's language in iOS Settings → Apps → byot.

Please also check Light and Dark Mode and the largest text size, and report anything that looks wrong.
