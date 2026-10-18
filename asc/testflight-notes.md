BYOT 1.0.35 — Pairing messages and live updates that come back

This build polishes what people using OpenCode's own iPhone app have been reporting on GitHub. Everything else is as in 1.0.34.

Please test:

Live updates after a network change
• Open a conversation and start a long prompt. Switch the phone from Wi-Fi to mobile data, or put the computer to sleep for a minute and wake it. Within about a minute the conversation must say it is reconnecting, then pick up the reply without a pull to refresh.
• Leave byot in the background for a few minutes while a reply runs, then come back. Live updates must resume right away instead of after a pause.

Pairing codes that can't work from a phone
• On a computer whose OpenCode only listens on 127.0.0.1 (the default), run opencode pair and paste the printed http://127.0.0.1 link into Scan pairing code › Paste. byot must say the address is the computer's own and suggest opencode pair --remote or opencode service set hostname 0.0.0.0, not that the computer is asleep.
• If opencode pair --remote prints a code but the relay isn't working, byot must say the relay is the problem and suggest opencode service restart.

Pairing with opencode pair and opencode pair --remote must still work as in 1.0.34. Also check these messages in Simplified Chinese.
