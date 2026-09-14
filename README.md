# BYOT

BYOT is a native iOS client for [OpenCode](https://opencode.ai), the open-source coding agent. It connects to the OpenCode server running on your own computer and lets you drive real coding sessions from your iPhone.

[**Download on the App Store**](https://apps.apple.com/us/app/byot/id6782403920) · [byot.app](https://byot.app)

<p align="center">
  <img src="docs/screenshots/01-connect-your-opencode-server.png" alt="Connect screen: add the HTTPS address of your OpenCode server, or try the demo session" width="32%">
  <img src="docs/screenshots/02-add-server-details.png" alt="Server details: name, HTTPS address, username, password, and an optional working directory" width="32%">
  <img src="docs/screenshots/03-streaming-session-with-tools.png" alt="A streaming session: reasoning, a completed shell command, and OpenCode working" width="32%">
</p>
<p align="center">
  <img src="docs/screenshots/04-approve-tool-permissions.png" alt="A permission request for a bash command: allow once, always allow, or reject" width="32%">
  <img src="docs/screenshots/05-answer-opencode-questions.png" alt="OpenCode asks which rate limiter to use, with choices or a custom answer" width="32%">
  <img src="docs/screenshots/06-review-session-diff.png" alt="Reviewing the session diff on the phone" width="32%">
</p>

## What it does

- Browse the projects and sessions on your server
- Send prompts and watch the full turn stream live — assistant text, reasoning, files, patches
- See every tool call with its input, progress, output, and errors
- Review session diffs before you trust the result
- Answer permission requests: allow once, always allow, or reject
- Answer questions with choices or your own text
- Queue follow-up prompts while a turn runs, or steer the current one
- Pick the model per prompt from your server's own catalog
- Follow your device's appearance, or choose Light or Dark from the home screen's information button

## Requirements

- An OpenCode server (1.18+) on a machine you control — `opencode serve`
- Reachable from your phone over **HTTPS** with Basic auth. [Tailscale](https://tailscale.com) (`tailscale serve`) is the usual path; any valid TLS endpoint works. The app refuses plain HTTP.

## Development

For the public landing page, see [web/README.md](./web/README.md).

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen
open BYOT.xcodeproj
```

Run the tests with the BYOT scheme, or:

```bash
xcodebuild test -project BYOT.xcodeproj -scheme BYOT -destination 'platform=iOS Simulator,name=iPhone 16'
```

The [OpenCode service layers](docs/opencode-service-layers.md) explain adapter
composition, dependency injection, discovery lifetime, and test seams.

## Status

Early, and the surface is intentionally small. Expect rough edges — [issues](https://github.com/steventsao/byot/issues) welcome.

## License

[MIT](./LICENSE). Bundled [Open Runde](https://github.com/lauridskern/open-runde) fonts keep their own license — see [Sources/Resources/THIRD-PARTY-NOTICES.txt](./Sources/Resources/THIRD-PARTY-NOTICES.txt).
