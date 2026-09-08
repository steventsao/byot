New in 1.0.12:

- Fix duplicate sessions in project grouping when OpenCode 1 returns both its global project and your configured directory. Sessions appear once, under their own directory, and remain available if one overlapping request fails.
- Repeatable end-to-end compatibility coverage now runs against upstream OpenCode 1.18.29 and OpenCode 2 beta 19271.

Retained from 1.0.11:

- Switch between saved servers using the horizontal server bar.
- Open sessions directly from the home screen. Projects are now an optional grouping, with expandable session lists.
- Sort sessions and project groups independently by recent activity, session status, or name. Your grouping and sort preferences are remembered.
- See Working, retry details, and last activity in the list. Project groups show session counts, active work, retries, and loading errors.
- Search session titles and project names or paths.
- Create a session in an existing project or another directory, then go straight to its chat.
- Sessions load progressively. A project or status error leaves other sessions usable, and unavailable status is labeled explicitly.

Please check server switching, grouping and sorting, direct chat navigation, and large text. Also verify System/Light/Dark appearance, Stop and retry for stalled turns, attachments, and model selection. Existing OpenCode 1 and OpenCode 2 support is retained.

Compatibility results and simulator screenshots: https://github.com/steventsao/byot/releases/tag/v1.0.12
