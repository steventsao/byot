# iOS CI and TestFlight releases

Two GitHub Actions workflows build the app. Neither depends on a developer's
Mac, keychain or web session.

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `iOS CI` (`.github/workflows/ios-ci.yml`) | Pull requests, pushes to `main`, manual | `xcodegen generate`, then a simulator build and the `BYOTTests` unit tests on `macos-26` with Xcode 26.5. The build is unsigned (`CODE_SIGNING_ALLOWED=NO`) and needs no secrets. The `.xcresult` is attached when it fails. |
| `iOS release` (`.github/workflows/ios-release.yml`) | Manual (`workflow_dispatch`) | Runs `iOS CI` first. Then it archives, exports, validates and uploads with `scripts/asc-build-testflight.sh`, adds the build to a beta group with the notes in `asc/testflight-notes.md`, and can submit it for external beta review. |

UI tests are not part of either workflow yet. They are slower and some depend
on simulator state. Run them with the scripts in `scripts/` when a change needs
them.

## Running a release

1. Set `MARKETING_VERSION` in `project.yml` and update
   `asc/testflight-notes.md` on the branch you want to ship.
2. In **Actions → iOS release → Run workflow**, pick that branch. Leave
   *version* blank to use `project.yml`, set the beta group (default
   `Internal Testers`), and tick *Submit for external beta review* only for an
   external build.
3. A reviewer approves the `testflight` environment, and the job runs.

The build number is the UTC time, `YYYYMMDDHHMMSS`. It always increases,
whether the build comes from CI or from a Mac. The run summary records the
version, build number, commit and group. The IPA and dSYMs are kept as a run
artifact for 30 days.

A dispatch workflow only shows up in the Actions tab once its file is on
`main`.

## How signing works

`scripts/ci/install-signing.sh` runs before the archive:

- It imports the Apple Distribution identity from a secret into a temporary
  keychain, and sets the key's partition list so `codesign` can use it without
  a prompt. This is what prevents `errSecInternalComponent` in a
  non-interactive job.
- It reads which extensions the `BYOT` target embeds from `project.yml`. For
  the app and each of those extensions, it downloads the newest active App
  Store profile that contains that certificate, using the App Store Connect
  API.
- It writes a manual-signing export-options plist and sets `BYOT_PROFILE_APP`,
  `BYOT_PROFILE_WIDGETS` and `BYOT_PROFILE_SHARE`. `project.yml` maps each
  variable to its own target's `PROVISIONING_PROFILE_SPECIFIER`. That way a
  profile never lands on every target, which is what happens when
  `PROVISIONING_PROFILE_SPECIFIER` is given on the `xcodebuild` command line.
  Local builds leave the variables empty and keep automatic signing.

`scripts/ci/remove-signing.sh` deletes the keychain, the profiles and the API
key when the job ends, even if it failed.

## One-time setup

### 1. App Store Connect API key

Create a team API key in App Store Connect under **Users and Access →
Integrations**. It needs the App Manager role with access to Certificates,
Identifiers & Profiles (or the Admin role). Without that access, the job cannot
list profiles.

### 2. Distribution certificate

Export the Apple Distribution certificate and its private key as a
password-protected `.p12`. Use the certificate that the App Store profiles are
issued for. Encode the file with `base64 -i distribution.p12 | pbcopy` and
delete the `.p12` afterwards.

### 3. App Store profiles

Each embedded bundle ID needs an active **App Store** profile that includes the
certificate:

| Bundle ID | Needed when |
| --- | --- |
| `com.steventsao.byot` | Always |
| `com.steventsao.byot.widgets` | `BYOT` depends on `BYOTWidgets` in `project.yml` |
| `com.steventsao.byot.share` | `BYOT` depends on `BYOTShare` in `project.yml` |

The extensions need the App Group first; see
[1.0.31-signing.md](releases/1.0.31-signing.md). After you enable App Groups on
`com.steventsao.byot`, create a **new** app profile. The existing one does not
include the group. The job picks the newest matching profile, so older ones can
stay.

### 4. The `testflight` environment and its secrets

In **Settings → Environments**, create `testflight`, add required reviewers,
and limit deployments to the release branches. Add these as environment
secrets:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | API key ID |
| `ASC_ISSUER_ID` | API issuer ID |
| `ASC_PRIVATE_KEY` | Contents of the `AuthKey_<id>.p8` file |
| `ASC_APP_ID` | The app's App Store Connect ID |
| `DIST_CERT_P12_BASE64` | Base64 of the distribution `.p12` |
| `DIST_CERT_P12_PASSWORD` | The `.p12` password |

To check the setup, run `iOS release` once for the internal group.

## Local fallback

`scripts/asc-build-testflight.sh` still works on a Mac with automatic signing.
Run it from an interactive terminal, so macOS can ask for access to the signing
key:

```bash
BYOT_UPLOAD_TESTFLIGHT=1 ASC_APP_ID=<app id> scripts/asc-build-testflight.sh
```

## Not done yet

- Releases triggered by tags (`ios/v*`) or by pushes to a release branch.
- Nightly UI tests and screenshot capture.
- Upload of dSYMs to a crash reporter. They are kept only as run artifacts.
