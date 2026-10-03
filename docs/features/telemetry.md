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
custom key outside the schema below and the `$device_name`, `$timezone`,
`$set` and `$set_once` context keys. PostHog derives a country and city from
the request address.

The SDK adds its own context to every event: `$app_version`, `$app_build`,
`$os_name`, `$os_version`, `$device_model`, `$device_type`, `$locale`,
`$is_testflight`, `$is_emulator`, `$lib`, `$lib_version`, screen size and
network type.

## Events

Six names. Each has a fixed set of property keys; a payload with any other
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

## Never sent

Prompts, replies, code, file contents, file names, directories, project and
session names, worktree names, server addresses and names, user names,
passwords, custom provider and agent names, error messages, stack traces,
the device's user-visible name, the time zone.

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
