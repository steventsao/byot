# iOS OpenCode connection and cutover acceptance

Status date: 2026-08-22
Protocol pin: OpenCode `3a31c4ea801915c0b050df4b3842997ea62b6e93`

## Ship decision

Ship one dual-stack BYOT build with explicit v1 and v2 detection/adapters. Do not require a hard v2 cutover yet.

The upstream issues called out by #18 remain open as of the status date:

- [#41696](https://github.com/anomalyco/opencode/issues/41696): managed v2 server startup hang
- [#41746](https://github.com/anomalyco/opencode/issues/41746): managed v2 server startup hang
- [#42671](https://github.com/anomalyco/opencode/issues/42671): v1-to-v2 history migration loss and server errors

A future hard-v2 decision requires all three blockers to be resolved, migration of representative real history to pass, and the device matrix below to be rerun. BYOT must retain the v1 adapter until that gate is explicitly changed in a new issue.

## Credential-safe API acceptance

The checker is read-only. It verifies authenticated health, project/location context, session listing, exact protocol envelopes, and exact directory/workspace query conventions. It keeps the Basic credential in a mode-600 temporary curl configuration and never prints the base URL, username, password, authorization header, or response body.

Run its deterministic v1/v2 fixture suite first:

```bash
scripts/test-opencode-acceptance.sh
```

Then run it once against each real server. Use HTTPS for Tailscale/manual profiles:

```bash
OPENCODE_BASE_URL="https://your-v1-server.example.ts.net" \
OPENCODE_PROTOCOL=v1 \
OPENCODE_USERNAME=opencode \
OPENCODE_PASSWORD="$(security find-generic-password -w -s byot-v1-test)" \
OPENCODE_DIRECTORY="/absolute/test/repository" \
scripts/opencode-acceptance.sh

OPENCODE_BASE_URL="https://your-v2-server.example.ts.net" \
OPENCODE_PROTOCOL=v2 \
OPENCODE_USERNAME=opencode \
OPENCODE_PASSWORD="$(security find-generic-password -w -s byot-v2-test)" \
OPENCODE_DIRECTORY="/absolute/test/repository" \
scripts/opencode-acceptance.sh
```

For a loopback, private-IP, or `.local` lab endpoint only, set `OPENCODE_ALLOW_LOCAL_HTTP=1`. The harness rejects public HTTP hosts even with that flag, matching the iOS discovery policy.

## Mac server preparation

Use separate ports and separate test data while comparing protocols. Substitute the locally installed v1/v2 executable paths; do not assume an alias points to the intended build.

```bash
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_PASSWORD="$(security find-generic-password -w -s byot-v1-test)"
/absolute/path/to/opencode-v1 serve --hostname 0.0.0.0 --port 4096

export OPENCODE_SERVER_PASSWORD="$(security find-generic-password -w -s byot-v2-test)"
/absolute/path/to/opencode2 serve --hostname 0.0.0.0 --port 4097
```

Before TestFlight testing, verify the exact binaries/versions, Tailscale ACL, macOS firewall, server passwords, test repository permissions, and backup/restore plan for any migrated history. Do not expose either port to the public internet.

## TestFlight device matrix

Use the same candidate build for both rows. Record screenshots or screen recordings without secrets.

| Check | v1 server | v2 server | Evidence |
| --- | --- | --- | --- |
| Add/test profile and reconnect after relaunch | ⬜ | ⬜ | |
| Browse project and root sessions | ⬜ | ⬜ | |
| Create session; send and stream a prompt | ⬜ | ⬜ | |
| Queue another prompt while busy; abort | ⬜ | ⬜ | |
| Permission reply and question answer/reject | ⬜ | ⬜ | |
| Model/provider catalog and authentication | ⬜ | ⬜ | |
| File search/read and changed-file behavior | ⬜ | ⬜ | |
| Rename/delete/history actions reflect capability gates | ⬜ | ⬜ | |
| Background/foreground and network interruption recovery | ⬜ | ⬜ | |
| Large Dynamic Type, VoiceOver labels, and sheet reachability | ⬜ | ⬜ | |

Expected v2 gaps must be explained in the UI and must not trigger guessed network routes. The current pinned gaps are documented beside their components in `docs/opencode-*.md` and asserted in `OpenCodeProtocolCapabilitiesTests` plus `OpenCodeV2ContractTests`.

## Evidence record

Complete this block in the release issue; never paste credentials or full server URLs.

```text
Date/time:
Tester:
BYOT build/version/commit:
iOS device and OS:
Mac model and macOS:
OpenCode v1 binary version/commit:
OpenCode v2 binary version/commit:
Network path (Tailscale/LAN):
Acceptance harness v1 result URL or log artifact:
Acceptance harness v2 result URL or log artifact:
Device matrix exceptions:
Upstream blocker status rechecked:
Ship/no-ship decision:
```

Code-level acceptance is automated by `.github/workflows/opencode-acceptance-harness.yml`. Real Mac mini, Tailscale, TestFlight, and migration sign-off are external release steps and are not satisfied by simulator or fixture results.
