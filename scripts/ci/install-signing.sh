#!/usr/bin/env bash
# Prepare manual App Store signing on a CI runner, for
# scripts/asc-build-testflight.sh.
#
# - Imports the distribution identity into a temporary keychain that
#   codesign can use without a prompt (the errSecInternalComponent fix).
# - Downloads, by App Store Connect API, the newest active App Store profile for
#   the app and for each extension the app embeds, keeping only profiles that
#   contain that certificate.
# - Writes an export-options plist that maps each bundle ID to its profile.
# - Appends the settings the release script reads to $GITHUB_ENV.
#
# Required environment:
#   DIST_CERT_P12_BASE64    base64 of the distribution .p12 (Apple or iPhone Distribution)
#   DIST_CERT_P12_PASSWORD  its password
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH  App Store Connect API key
#   RUNNER_TEMP, GITHUB_ENV (set by GitHub Actions)
#
# scripts/ci/remove-signing.sh deletes the keychain and profiles afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

: "${DIST_CERT_P12_BASE64:?}"
: "${DIST_CERT_P12_PASSWORD:?}"
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"

SIGNING_DIR="$RUNNER_TEMP/byot-signing"
KEYCHAIN="$SIGNING_DIR/byot-signing.keychain-db"
KEYCHAIN_PASSWORD_FILE="$SIGNING_DIR/keychain-password"
P12="$SIGNING_DIR/distribution.p12"
EXPORT_OPTIONS="$SIGNING_DIR/ExportOptions.plist"
PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
umask 077

# Only the extensions the BYOT target depends on are embedded and need a
# profile; a release branch can drop them (see docs/releases/1.0.31-signing.md).
BUNDLE_IDS=(com.steventsao.byot)
PROFILE_VARS=(BYOT_PROFILE_APP)
if grep -Eq '^ *- target: BYOTWidgets *$' project.yml; then
  BUNDLE_IDS+=(com.steventsao.byot.widgets)
  PROFILE_VARS+=(BYOT_PROFILE_WIDGETS)
fi
if grep -Eq '^ *- target: BYOTShare *$' project.yml; then
  BUNDLE_IDS+=(com.steventsao.byot.share)
  PROFILE_VARS+=(BYOT_PROFILE_SHARE)
fi
TEAM_ID="$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -n 1)"

# Temporary keychain. The partition list lets codesign use the key without the
# access prompt that a non-interactive session can never answer.
openssl rand -base64 32 > "$KEYCHAIN_PASSWORD_FILE"
KEYCHAIN_PASSWORD="$(<"$KEYCHAIN_PASSWORD_FILE")"
echo "::add-mask::$KEYCHAIN_PASSWORD"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
printf '%s' "$DIST_CERT_P12_BASE64" | base64 --decode > "$P12"
security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$DIST_CERT_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

current_keychains=()
while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  current_keychains+=("${keychain%\"*}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${current_keychains[@]}"

# Older teams' certificates are named "iPhone Distribution", newer ones
# "Apple Distribution"; select the identity by its SHA-1 so either works.
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN" |
  sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "((Apple|iPhone) Distribution: .*)"$/\1\t\2/p')"
if [[ "$(printf '%s' "$IDENTITIES" | grep -c . || true)" != "1" ]]; then
  echo "Expected exactly one valid distribution identity in the .p12." >&2
  exit 1
fi
IDENTITY_SHA1="${IDENTITIES%%$'\t'*}"
IDENTITY_NAME="${IDENTITIES#*$'\t'}"
echo "Signing identity: $IDENTITY_NAME"
CERT_SERIAL="$(security find-certificate -a -Z -p "$KEYCHAIN" |
  awk -v sha="$IDENTITY_SHA1" '/^SHA-1 hash:/ { keep = ($3 == sha) } keep' |
  openssl x509 -noout -serial | sed 's/^serial=//')"

# Profiles: newest active IOS_APP_STORE profile per bundle ID that includes the
# imported certificate.
asc profiles list \
  --profile-type IOS_APP_STORE \
  --profile-state ACTIVE \
  --fields name,uuid,createdDate,expirationDate,profileContent,bundleId,certificates \
  --include bundleId,certificates \
  --bundle-id-fields identifier \
  --certificate-fields serialNumber \
  --limit 200 \
  --paginate \
  --output json > "$SIGNING_DIR/profiles.json"

CERT_SERIAL="$CERT_SERIAL" python3 - "$SIGNING_DIR" "${BUNDLE_IDS[@]}" <<'PY' > "$SIGNING_DIR/selected.tsv"
import base64, json, os, sys

signing_dir, bundle_ids = sys.argv[1], sys.argv[2:]
norm = lambda serial: serial.upper().lstrip("0")
want_serial = norm(os.environ["CERT_SERIAL"])

with open(os.path.join(signing_dir, "profiles.json")) as f:
    text = f.read()
decoder, pos, pages = json.JSONDecoder(), 0, []
while pos < len(text):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos == len(text):
        break
    page, pos = decoder.raw_decode(text, pos)
    pages.append(page)

profiles, included = [], {}
for page in pages:
    profiles += page.get("data", [])
    for item in page.get("included", []):
        included[(item["type"], item["id"])] = item["attributes"]

missing = []
for bundle_id in bundle_ids:
    matches = []
    for profile in profiles:
        rel = profile.get("relationships", {})
        bundle = rel.get("bundleId", {}).get("data") or {}
        if included.get(("bundleIds", bundle.get("id")), {}).get("identifier") != bundle_id:
            continue
        serials = {
            norm(included.get(("certificates", c["id"]), {}).get("serialNumber", ""))
            for c in rel.get("certificates", {}).get("data", [])
        }
        if want_serial in serials:
            matches.append(profile["attributes"])
    if not matches:
        missing.append(bundle_id)
        continue
    best = max(matches, key=lambda a: a.get("createdDate") or "")
    path = os.path.join(signing_dir, best["uuid"] + ".mobileprovision")
    with open(path, "wb") as out:
        out.write(base64.b64decode(best["profileContent"]))
    print(f"{bundle_id}\t{best['uuid']}\t{best['name']}")

if missing:
    sys.exit(
        "No active App Store profile with the distribution certificate for: "
        + ", ".join(missing)
        + ". Create one (docs/ci.md) and rerun."
    )
PY
rm -f "$SIGNING_DIR/profiles.json"

for dir in "${PROFILE_DIRS[@]}"; do
  mkdir -p "$dir"
done

rm -f "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy \
  -c 'Add :method string app-store-connect' \
  -c 'Add :signingStyle string manual' \
  -c "Add :signingCertificate string $IDENTITY_SHA1" \
  -c "Add :teamID string $TEAM_ID" \
  -c 'Add :uploadSymbols bool true' \
  -c 'Add :manageAppVersionAndBuildNumber bool false' \
  -c 'Add :provisioningProfiles dict' \
  "$EXPORT_OPTIONS" >/dev/null

index=0
while IFS=$'\t' read -r bundle_id uuid name; do
  for dir in "${PROFILE_DIRS[@]}"; do
    cp "$SIGNING_DIR/$uuid.mobileprovision" "$dir/$uuid.mobileprovision"
  done
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$bundle_id string $uuid" "$EXPORT_OPTIONS" >/dev/null
  echo "${PROFILE_VARS[$index]}=$uuid" >> "$GITHUB_ENV"
  echo "Signing $bundle_id with profile \"$name\"."
  index=$((index + 1))
done < "$SIGNING_DIR/selected.tsv"

{
  echo "BYOT_CODE_SIGN_KEYCHAIN=$KEYCHAIN"
  echo "BYOT_CODE_SIGN_KEYCHAIN_PASSWORD_FILE=$KEYCHAIN_PASSWORD_FILE"
  echo "BYOT_CODE_SIGN_IDENTITY=$IDENTITY_SHA1"
  echo "BYOT_EXPORT_OPTIONS_PLIST=$EXPORT_OPTIONS"
  echo "BYOT_ALLOW_PROVISIONING_UPDATES=0"
} >> "$GITHUB_ENV"
