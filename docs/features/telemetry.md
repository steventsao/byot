# Usage data (telemetry)

byot can send anonymous product usage events. It is **off until the person
turns it on**, and it never carries anything a person typed or named. This
file is the contract: the code in `Sources/BYOTTelemetry.swift` and
`Sources/BYOTTelemetryOpenCode.swift` enforces exactly what is written here,
and the privacy policy at byot.app/privacy describes the same thing in plain
words. Change all three together.

The design borrows from two open-source agent apps: the size of
[T3 Code](https://github.com/pingdotgg/t3code)'s telemetry (a handful of
server-side events) and the rules of [Orca](https://github.com/stablyai/orca)'s
(a fixed schema, fail-closed validation, consent before anything is sent).

## Consent and gates

Events leave the device only when **all** of these hold:

| Gate | Where |
| --- | --- |
| The person turned usage data on, in the one-time question or in About byot → Privacy | `BYOTTelemetry.consent == .enabled`, stored at `byot.telemetry.consent` |
| The process is not a unit test or a UI fixture | `BYOTLaunch.isAutomated == false` |
| No kill switch: `--telemetry-disabled` launch argument or `BYOT_TELEMETRY_DISABLED=1` | `BYOTTelemetry.Environment.killSwitch` |
| The bundle identifier is `com.steventsao.byot` | A fork that ships under another id sends nothing |

The question appears once, 1.5 s after the first launch in which a server is
saved and no other sheet is up. Closing it without choosing counts as
"Not now". Turning usage data **off** stops the SDK, forgets the install id,
and drops anything queued. Turning it on again creates a new install id.

## Identity

Events are keyed by `install_id`, a random UUID created on the device when
usage data is turned on (`byot.telemetry.install-id`). It is the PostHog
distinct id. PostHog person profiles are off (`personProfiles = .never`), so
no profile is ever built around it. There is no account, email, name, or
IP-based identity.

## Vendor

PostHog Cloud, US region (`us.i.posthog.com`), project 476731. The SDK runs
with every automatic capture off: no lifecycle or screen events, no
swizzling, no feature flags, no remote config, no session replay, no
exception capture, no surveys. A `PostHogPropertiesSanitizer` drops any
custom key outside the schema below and these context keys: `$device_name`,
`$timezone`, `$locale`, `$screen_height`, `$screen_width`, `$network_wifi`,
`$network_cellular`, `$set`, `$set_once`. PostHog derives a country from the
request address, then discards the address: project 476731 has "Discard
client IP data" on, so no `$ip` is stored, and a "Filter Properties"
transformation drops the city, postal code, coordinates, subdivision and
time-zone fields that the GeoIP step adds. Country and continent are the
only location. Session and device continuity come from the install id and
the SDK's `$session_id`, not from the address.

The SDK context that remains on every event: `$app_version`, `$app_build`,
`$app_name`, `$app_namespace`, `$os_name`, `$os_version`, `$device_model`,
`$device_type`, `$device_manufacturer`, `$is_testflight`, `$is_emulator`,
`$lib`, `$lib_version`.

## Events

Seven names. Each has a fixed set of property keys; a payload with any other
key, an empty or over-long string (more than 64 characters), or any value
that is not a string, integer, boolean or finite number is dropped whole and
counted in `droppedEventCount`.

| Event | Properties | When |
| --- | --- | --- |
| `app_opened` | `launch`: `cold`, `resume`, `opt_in` | Cold launch, return to the foreground, or the moment usage data is turned on |
| `server_connected` | `transport`: `https` / `http` · `host_kind`: `tailscale` / `local_address` / `local_name` / `public` / `unknown` · `server_protocol`: `v1` / `v2` · `server_version`: `major.minor` or `unknown` · `compatibility`: `compatible` / `degraded` / `unsupported` / `unknown` | The first successful protocol negotiation per saved server per launch |
| `session_started` | `server_protocol` | A session is created from byot (new session, worktree, Siri, share) |
| `turn_requested` | `kind`: `prompt` / `command` / `skill` / `shell` · `delivery`: `now` / `queued` / `computer_queue` · `agent`: `build` / `plan` / `other` / `none` · `provider`: an OpenCode provider id or `other` / `none` · `model`: a catalog model id, or `other` under a custom provider, or `none` · `variant_set` · `attachment_count` · `file_reference_count` | The person sends a message, a slash command, a skill, or a shell command |
| `turn_completed` | `result`: `completed` / `failed` / `stopped` · `duration_ms` · `agent` · `provider` · `model` · `input_tokens` · `output_tokens` · `reasoning_tokens` · `reply_count` | A turn byot requested goes idle while its conversation is open |
| `error_occurred` | `error_class` (see below) · `surface`: `connection` / `session_list` / `send` / `turn` / `shell` | A session list fails to load, a send fails, or the server reports a failed turn |
| `nudge_outcome` | `kind`: `star_card` / `review_request` · `outcome`: `shown` / `starred` / `later` / `requested` · `completed_turns` · `threshold` | byot asks for a GitHub star or Apple's review prompt after a completed turn, and what the person chose; see [star-nudge.md](star-nudge.md) |

`host_kind` classifies the address and never carries it: `*.ts.net` or a
100.64/10 address is `tailscale`; a numeric private address is
`local_address`; a `.local` or bare name is `local_name`; anything else is
`public`.

`provider` and `model` are reported only for provider ids OpenCode ships
(`BYOTTelemetryOpenCode.knownProviders`). A self-named provider, and every
model under it, reports as `other`. `agent` is `build` or `plan` for
OpenCode's primary agents; a custom agent is `other`.

`error_class` values: `authentication`, `not_found`, `throttled`,
`server_error`, `http_error`, `invalid_profile`, `invalid_response`,
`event_stream`, `server_message`, `model_unavailable`, `timeout`,
`unreachable`, `tls`, `app_transport_security`, `network`, `cancelled`,
`other`; and for failed turns `aborted`, `provider_auth`, `output_length`,
`provider_api`, `context_overflow`, `turn_failed`.

Token totals cover the replies to the turn's own user message as loaded when
the turn settles; a reply that has not arrived yet is not counted. A turn
whose conversation is closed before it ends is not reported at all.

## How this compares

The bar is "what OpenCode, T3 Code and Orca do, and not more", checked on
2026-10-03 against their repositories.

| | OpenCode (`sst/opencode`) | T3 Code (`pingdotgg/t3code`) | Orca (`stablyai/orca`) | BYOT |
| --- | --- | --- | --- | --- |
| Product analytics | None in the CLI, server, web or desktop app | PostHog, 5 events, server-side | PostHog, 88 events, desktop only | PostHog, 7 events |
| Error reporting | Sentry in the web and desktop apps when a DSN is built in (Breadcrumbs off) | None | Local trace file; bundle upload only by hand | None; one coarse `error_class` |
| Consent | n/a | Opt-out: `T3CODE_TELEMETRY_ENABLED=false` | Opt-in banner, Settings switch, `DO_NOT_TRACK`, `ORCA_TELEMETRY_DISABLED`, CI off | Opt-in question, About switch, `--telemetry-disabled`, `BYOT_TELEMETRY_DISABLED=1`, tests off, forks off |
| Identity | n/a | Hashed provider account id, else install id | Random install id, no person profile | Random install id, no person profile, deleted on opt-out |
| Per turn | n/a | provider, model, reasoning effort, permission mode, result, duration, token totals | agent kind, token counts, coarse error class | kind, provider, model, agent (build/plan/other), result, duration, token totals, counts |
| Server or host | n/a | client surface, platform, arch | host OS, arch, glibc, Node major, local/WSL/SSH | address kind (tailnet/local/public), transport, protocol, `major.minor` version |
| Device context | n/a | platform, arch, app version | version, OS, arch, coarse OS release, channel | app and OS versions, device model and type |
| Location | n/a | PostHog default (IP stored unless the project discards it) | Country only; GeoIP off in the client | Country only; IP discarded at ingestion, city fields filtered |
| Star or review ask | None | None | Desktop star card: threshold, 3-day cooldown, doubled on dismiss; none on iOS | Star card: third turn, 6-day cooldown, doubled on Later; then Apple's prompt |
| Mobile app | Desktop and web only | iOS and Android companions, events from the server | iOS and Android companion: no telemetry, no nag | The phone is the product |

Everything BYOT sends appears in at least one of the three; nothing in BYOT
goes finer than its counterpart there.

## Never sent

Prompts, replies, code, file contents, file names, directories, project and
session names, worktree names, server addresses and names, user names,
passwords, custom provider and agent names, error messages, stack traces,
the device's user-visible name, the time zone, the language, the screen size,
the network type, city-level location.

## Changing the schema

1. Add the key to `BYOTTelemetryEvent.allowedProperties` and, if it is an
   enum, the vocabulary in `BYOTTelemetryOpenCode`.
2. Add the row here and the sentence in `web/src/information.ts`.
3. Extend `Tests/BYOTTelemetryTests.swift`; `mappingsFitSchema` must still
   report zero dropped events.
4. If the data type changes, update `Sources/PrivacyInfo.xcprivacy` and the
   App Privacy answers in App Store Connect.

## Checking it

- `xcodebuild test … -only-testing:BYOTTests/BYOTTelemetrySchemaTests
  -only-testing:BYOTTests/BYOTTelemetryConsentTests
  -only-testing:BYOTTests/BYOTTelemetryVocabularyTests`
- On a device: turn usage data on in About byot, send a prompt, then look for
  `turn_requested` and `turn_completed` in PostHog project 476731 with
  `$is_testflight = true`.
