BYOT 1.0.38 — Session list says "Connecting", and usage data stops over-reporting

This build is the current `main`: the 1.0.36 session-list change plus two usage-data corrections. Note for anyone on 1.0.37: that build also carried a workspace-state fix that is not on `main` and so is not in this build.

Please test:

Opening byot while a server is still answering
• Quit byot, then open it on a server whose sessions you have seen before. While byot reaches the server, the saved sessions must say "Connecting", not "Status unavailable". Once the server answers, each row shows its real status (Idle, Working, Needs input).
• Put that computer to sleep, or turn its OpenCode off, and open byot again. After the "Showing sessions saved …" notice appears at the top, the saved rows show no status at all, since none is known.
• "Status unavailable" is now kept for a server that answered with an error. That project's error appears in the list with the reason. Also check the list in Simplified Chinese.

Usage data, if you have it on
• Leave and reopen the session list a few times, and switch away from byot while it is loading. Those cancelled loads are no longer counted as network errors, so About byot > Privacy should not imply errors you did not see.
• On a launch where you answer "Share anonymous usage data?" with Share, the server you are connected to is now counted once you opt in. Answering "Not now" still sends nothing.
