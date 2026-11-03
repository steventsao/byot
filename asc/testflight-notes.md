BYOT 1.0.39 — Cancelled loads stop showing false errors, and permission prompts read properly

This build merges the 1.0.37 work back onto `main` alongside the 1.0.38 changes, so it is the first build that has all of it: the session-list wording, the workspace-screen fix, the usage-data corrections, and English permission explanations.

Please test:

Leaving a screen while it is still loading
• Open the projects/workspace screen on a server, then immediately switch away from byot or go back. Coming back must not show an error. Before this build, a cancelled request was treated as a real failure and could leave an error message and a blank workspace behind.
• Do the same on the session list. Saved sessions say "Connecting" while byot reaches the server, not "Status unavailable". Once the server answers, each row shows its real status (Idle, Working, Needs input).
• Put that computer to sleep, or turn its OpenCode off, and open byot again. After the "Showing sessions saved …" notice appears, the saved rows show no status at all, since none is known. "Status unavailable" is now kept for a server that answered with an error, and that project shows the reason.

Permission prompts
• Trigger the camera prompt (add a server by scanning a pairing code), the microphone and speech prompts (voice dictation in the composer), and the local-network prompt (find a server nearby). Each must show a sentence explaining why, not a blank prompt or a raw key name. Check in English and in Simplified Chinese.

Usage data, if you have it on
• Leave and reopen the session list a few times, and switch away from byot while it is loading. Those cancelled loads are no longer counted as network errors.
• On a launch where you answer "Share anonymous usage data?" with Share, the server you are connected to is counted once you opt in. Answering "Not now" still sends nothing.
