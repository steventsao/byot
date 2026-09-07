BYOT 1.0.8 adds automatic OpenCode 2 beta support while preserving OpenCode 1 connections.

Please test connecting to your existing server, browsing projects and sessions, selecting a model, sending messages and attachments, live replies and tool output, approving permissions, answering forms, stopping a turn, and reconnecting after switching apps.

OpenCode 2 is validated against 0.0.0-beta-19242. The app detects the protocol and prompt/form contract automatically. This beta does not provide changes for individual sessions or provider connection status; BYOT explains those limitations in the app.

Queued prompt retries retain the same admission ID to avoid duplicates after an uncertain connection. Existing stalled-session recovery remains available.
