BYOT 1.0.41 — OpenCode 2 fixes: no stray "Idle", sessions from every worktree

Everything in 1.0.40 is here too. This build fixes three things reported against OpenCode 2.

Please test:

Finished replies
• Send a prompt to an OpenCode 2 server and let it finish. The reply ends with its last sentence. It no longer ends with the word "Idle". The header still says "Worked for …", and the session status still says Idle.
• Fold and unfold the finished turn. "Idle" should not appear in either.

Sessions in Git worktrees
• Use a repository that has an extra Git worktree, with sessions in both the main checkout and the worktree. Leave "Working directory" empty in the connection settings.
• Open the project. Sessions from the worktree are listed with the main checkout's, without setting a working directory. Each session appears once.
• Open a worktree session and check that its status (Working or Idle) is right.

Queued prompts
• While a reply is running, queue a second prompt. If it pauses with "Waiting to retry", remove it. The session goes back to normal, with no "Couldn't load this session" message.

Things that should not change
• Sessions on OpenCode 1 servers, and with a working directory set, list as before.
• Check in English and in Simplified Chinese.
