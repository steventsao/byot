#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$IOS_DIR"

if ! command -v asc >/dev/null 2>&1; then
  echo "asc CLI is required. Install/authenticate it, then retry." >&2
  exit 127
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Run this on a Mac with Xcode installed." >&2
  exit 127
fi

run_asc() {
  if [[ -n "${ASC_PROFILE:-}" ]]; then
    asc --profile "$ASC_PROFILE" "$@"
  else
    asc "$@"
  fi
}

BYOT_VERSION="${BYOT_VERSION:-1.0.12}"
# 14-digit YYYYMMDDHHMMSS: monotonically increasing and always larger than the
# 20260624152336 build that poisoned the sequence. A 12-digit %Y%m%d%H%M number is
# numerically smaller than that one, so iOS/TestFlight treats such builds as
# downgrades (CFBundleVersion is compared numerically) and offers no update.
BYOT_BUILD="${BYOT_BUILD:-$(date +%Y%m%d%H%M%S)}"
BYOT_BUNDLE_ID="${BYOT_BUNDLE_ID:-com.steventsao.byot}"
# Archive the BYOT OpenCode client.
BYOT_SCHEME="${BYOT_SCHEME:-BYOT}"
ARCHIVE_PATH="${BYOT_ARCHIVE_PATH:-.asc/artifacts/BYOT.xcarchive}"
IPA_PATH="${BYOT_IPA_PATH:-.asc/artifacts/BYOT.ipa}"
EXPORT_OPTIONS_PLIST="${BYOT_EXPORT_OPTIONS_PLIST:-ExportOptions.plist}"
XCODE_DESTINATION="${BYOT_XCODE_DESTINATION:-generic/platform=iOS}"
ALLOW_PROVISIONING_UPDATES="${BYOT_ALLOW_PROVISIONING_UPDATES:-1}"
DEFAULT_CODE_SIGN_KEYCHAIN="$HOME/Library/Keychains/shared-ios-signing-C4WC5AA4T8.keychain-db"
DEFAULT_CODE_SIGN_PASSWORD_FILE="$HOME/dev/apikeys/shared-ios-signing-C4WC5AA4T8/keychain.password"

if [[ -z "${BYOT_CODE_SIGN_KEYCHAIN:-}" && -f "$DEFAULT_CODE_SIGN_KEYCHAIN" ]]; then
  BYOT_CODE_SIGN_KEYCHAIN="$DEFAULT_CODE_SIGN_KEYCHAIN"
fi

mkdir -p .asc/artifacts

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

run_asc xcode version edit \
  --project BYOT.xcodeproj \
  --version "$BYOT_VERSION" \
  --build-number "$BYOT_BUILD"

archive_flags=(
  --xcodebuild-flag=-destination
  --xcodebuild-flag="$XCODE_DESTINATION"
  --xcodebuild-flag=PRODUCT_BUNDLE_IDENTIFIER="$BYOT_BUNDLE_ID"
)
export_flags=()
validate_args=()

SWIFTPM_CACHE_PATH="$HOME/Library/Caches/org.swift.swiftpm"
SWIFTPM_ISOLATION="${BYOT_ISOLATE_SWIFTPM_CACHE:-auto}"
if [[ "$SWIFTPM_ISOLATION" == "1" ||
      ( "$SWIFTPM_ISOLATION" == "auto" && -L "$SWIFTPM_CACHE_PATH" && ! -e "$SWIFTPM_CACHE_PATH" ) ]]; then
  RELEASE_CACHE_ROOT="${BYOT_RELEASE_CACHE_ROOT:-$(mktemp -d /tmp/byot-asc-release.XXXXXX)}"
  FIXED_USER_HOME="$RELEASE_CACHE_ROOT/UserHome"
  mkdir -p \
    "$FIXED_USER_HOME/Library/Caches" \
    "$FIXED_USER_HOME/Library/MobileDevice/Provisioning Profiles" \
    "$FIXED_USER_HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$RELEASE_CACHE_ROOT/DerivedData" \
    "$RELEASE_CACHE_ROOT/SourcePackages" \
    "$RELEASE_CACHE_ROOT/PackageCache" \
    "$RELEASE_CACHE_ROOT/SwiftPMModuleCache" \
    "$RELEASE_CACHE_ROOT/ClangModuleCache"

  INSTALLED_PROFILES="$HOME/Library/MobileDevice/Provisioning Profiles"
  if [[ -d "$INSTALLED_PROFILES" ]]; then
    ditto "$INSTALLED_PROFILES" "$FIXED_USER_HOME/Library/MobileDevice/Provisioning Profiles"
  fi
  XCODE_INSTALLED_PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  if [[ -d "$XCODE_INSTALLED_PROFILES" ]]; then
    ditto "$XCODE_INSTALLED_PROFILES" "$FIXED_USER_HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  fi

  export CFFIXED_USER_HOME="$FIXED_USER_HOME"
  export SWIFTPM_MODULECACHE_OVERRIDE="$RELEASE_CACHE_ROOT/SwiftPMModuleCache"
  export CLANG_MODULE_CACHE_PATH="$RELEASE_CACHE_ROOT/ClangModuleCache"
  archive_flags+=(
    --xcodebuild-flag=-derivedDataPath
    --xcodebuild-flag="$RELEASE_CACHE_ROOT/DerivedData"
    --xcodebuild-flag=-clonedSourcePackagesDirPath
    --xcodebuild-flag="$RELEASE_CACHE_ROOT/SourcePackages"
    --xcodebuild-flag=-packageCachePath
    --xcodebuild-flag="$RELEASE_CACHE_ROOT/PackageCache"
    --xcodebuild-flag=-disablePackageRepositoryCache
    --xcodebuild-flag=-onlyUsePackageVersionsFromResolvedFile
    --xcodebuild-flag=-skipPackageUpdates
  )
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  archive_flags+=(--xcodebuild-flag=-allowProvisioningUpdates)
  export_flags+=(--xcodebuild-flag=-allowProvisioningUpdates)
fi

CODE_SIGN_KEYCHAIN=""
CODE_SIGN_KEYCHAIN_WAS_LOCKED=0
CODE_SIGN_KEYCHAIN_UNLOCKED=0
KEYCHAIN_SEARCH_LIST_CHANGED=0
ORIGINAL_USER_KEYCHAINS=()
IPA_INFO_PLIST=""

keychain_security() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${BYOT_KEYCHAIN_SECURITY_TIMEOUT:-15}" security "$@"
  else
    security "$@"
  fi
}

cleanup_release_signing() {
  if [[ "$KEYCHAIN_SEARCH_LIST_CHANGED" == "1" && ${#ORIGINAL_USER_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null || true
  fi
  if [[ "$CODE_SIGN_KEYCHAIN_UNLOCKED" == "1" && "$CODE_SIGN_KEYCHAIN_WAS_LOCKED" == "1" ]]; then
    keychain_security lock-keychain "$CODE_SIGN_KEYCHAIN" >/dev/null || true
  fi
  if [[ -n "$IPA_INFO_PLIST" && -f "$IPA_INFO_PLIST" ]]; then
    rm -f "$IPA_INFO_PLIST" || true
  fi
}
trap cleanup_release_signing EXIT

if [[ -n "${BYOT_CODE_SIGN_KEYCHAIN:-}" ]]; then
  CODE_SIGN_KEYCHAIN="${BYOT_CODE_SIGN_KEYCHAIN/#\~/$HOME}"
  if [[ ! -f "$CODE_SIGN_KEYCHAIN" ]]; then
    echo "BYOT_CODE_SIGN_KEYCHAIN does not exist: $CODE_SIGN_KEYCHAIN" >&2
    exit 1
  fi
  if [[ -n "${BYOT_CODE_SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]]; then
    CODE_SIGN_KEYCHAIN_PASSWORD_FILE="${BYOT_CODE_SIGN_KEYCHAIN_PASSWORD_FILE/#\~/$HOME}"
  elif [[ "$CODE_SIGN_KEYCHAIN" == "$DEFAULT_CODE_SIGN_KEYCHAIN" && -f "$DEFAULT_CODE_SIGN_PASSWORD_FILE" ]]; then
    CODE_SIGN_KEYCHAIN_PASSWORD_FILE="$DEFAULT_CODE_SIGN_PASSWORD_FILE"
  else
    CODE_SIGN_KEYCHAIN_PASSWORD_FILE="$(dirname "$CODE_SIGN_KEYCHAIN")/byot-upload.keychain-password.txt"
  fi

  if ! keychain_security show-keychain-info "$CODE_SIGN_KEYCHAIN" >/dev/null 2>&1; then
    CODE_SIGN_KEYCHAIN_WAS_LOCKED=1
  fi
  if [[ -f "$CODE_SIGN_KEYCHAIN_PASSWORD_FILE" ]]; then
    if ! keychain_security unlock-keychain -p "$(<"$CODE_SIGN_KEYCHAIN_PASSWORD_FILE")" "$CODE_SIGN_KEYCHAIN"; then
      echo "Could not unlock signing keychain within the configured timeout: $CODE_SIGN_KEYCHAIN" >&2
      exit 1
    fi
    CODE_SIGN_KEYCHAIN_UNLOCKED=1
  elif [[ "$CODE_SIGN_KEYCHAIN_WAS_LOCKED" == "1" ]]; then
    echo "Signing keychain is locked and no password file exists: $CODE_SIGN_KEYCHAIN_PASSWORD_FILE" >&2
    exit 1
  fi

  while IFS= read -r keychain; do
    keychain="${keychain#*\"}"
    keychain="${keychain%\"*}"
    if [[ -n "$keychain" ]]; then
      ORIGINAL_USER_KEYCHAINS+=("$keychain")
    fi
  done < <(security list-keychains -d user)

  SIGNING_SEARCH_KEYCHAINS=("$CODE_SIGN_KEYCHAIN")
  for keychain in "${ORIGINAL_USER_KEYCHAINS[@]}"; do
    if [[ "$keychain" != "$CODE_SIGN_KEYCHAIN" ]]; then
      SIGNING_SEARCH_KEYCHAINS+=("$keychain")
    fi
  done
  security list-keychains -d user -s "${SIGNING_SEARCH_KEYCHAINS[@]}"
  KEYCHAIN_SEARCH_LIST_CHANGED=1

  archive_flags+=(--xcodebuild-flag="OTHER_CODE_SIGN_FLAGS=--keychain ${CODE_SIGN_KEYCHAIN}")
  export_flags+=(--xcodebuild-flag="OTHER_CODE_SIGN_FLAGS=--keychain ${CODE_SIGN_KEYCHAIN}")
fi
if [[ -z "${ASC_PRIVATE_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
  ASC_AUTH_FIELDS="$(node <<'NODE'
const fs = require("fs");
const path = require("path");
const configPath = path.join(process.env.HOME || "", ".asc", "config.json");
try {
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const key = Array.isArray(config.keys)
    ? config.keys.find((item) => item.name === config.default_key_name) || config.keys[0]
    : {};
  const privateKeyPath = config.private_key_path || key.private_key_path || "";
  const keyId = config.key_id || key.key_id || "";
  const issuerId = config.issuer_id || key.issuer_id || "";
  process.stdout.write([privateKeyPath, keyId, issuerId].join("\n"));
} catch {
  process.stdout.write("\n\n");
}
NODE
)"
  ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$(printf '%s' "$ASC_AUTH_FIELDS" | sed -n '1p')}"
  ASC_KEY_ID="${ASC_KEY_ID:-$(printf '%s' "$ASC_AUTH_FIELDS" | sed -n '2p')}"
  ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(printf '%s' "$ASC_AUTH_FIELDS" | sed -n '3p')}"
fi
if [[ -n "${ASC_PRIVATE_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_PRIVATE_KEY_PATH/#\~/$HOME}" ]]; then
  AUTH_KEY_PATH="${ASC_PRIVATE_KEY_PATH/#\~/$HOME}"
  archive_flags+=(
    --xcodebuild-flag=-authenticationKeyPath
    --xcodebuild-flag="$AUTH_KEY_PATH"
    --xcodebuild-flag=-authenticationKeyID
    --xcodebuild-flag="$ASC_KEY_ID"
    --xcodebuild-flag=-authenticationKeyIssuerID
    --xcodebuild-flag="$ASC_ISSUER_ID"
  )
  export_flags+=(
    --xcodebuild-flag=-authenticationKeyPath
    --xcodebuild-flag="$AUTH_KEY_PATH"
    --xcodebuild-flag=-authenticationKeyID
    --xcodebuild-flag="$ASC_KEY_ID"
    --xcodebuild-flag=-authenticationKeyIssuerID
    --xcodebuild-flag="$ASC_ISSUER_ID"
  )
  validate_args+=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
  export API_PRIVATE_KEYS_DIR
  API_PRIVATE_KEYS_DIR="$(dirname "$AUTH_KEY_PATH")"
fi

run_asc xcode archive \
  --project BYOT.xcodeproj \
  --scheme "$BYOT_SCHEME" \
  --configuration Release \
  --clean \
  --overwrite \
  --archive-path "$ARCHIVE_PATH" \
  "${archive_flags[@]}" \
  --output json

run_asc xcode export \
  --archive-path "$ARCHIVE_PATH" \
  --export-options "$EXPORT_OPTIONS_PLIST" \
  --ipa-path "$IPA_PATH" \
  --overwrite \
  "${export_flags[@]}" \
  --output json

ARCHIVE_INFO_PLIST="$ARCHIVE_PATH/Info.plist"
if [[ ! -f "$ARCHIVE_INFO_PLIST" ]]; then
  echo "Archive metadata is missing: $ARCHIVE_INFO_PLIST" >&2
  exit 1
fi

IPA_INFO_ENTRY="$(unzip -Z1 "$IPA_PATH" | awk '$0 ~ "^Payload/[^/]+[.]app/Info[.]plist$" && entry == "" { entry=$0 } END { print entry }')"
if [[ -z "$IPA_INFO_ENTRY" ]]; then
  echo "Exported IPA does not contain a top-level app Info.plist: $IPA_PATH" >&2
  exit 1
fi
IPA_INFO_PLIST="$(mktemp "${TMPDIR:-/tmp}/byot-ipa-info.XXXXXX")"
unzip -p "$IPA_PATH" "$IPA_INFO_ENTRY" > "$IPA_INFO_PLIST"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

assert_metadata_value() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "Release metadata mismatch for $label: expected '$expected', got '$actual'." >&2
    exit 1
  fi
}

ARCHIVE_VERSION="$(plist_value "$ARCHIVE_INFO_PLIST" 'ApplicationProperties:CFBundleShortVersionString')"
ARCHIVE_BUILD="$(plist_value "$ARCHIVE_INFO_PLIST" 'ApplicationProperties:CFBundleVersion')"
ARCHIVE_BUNDLE_ID="$(plist_value "$ARCHIVE_INFO_PLIST" 'ApplicationProperties:CFBundleIdentifier')"
IPA_VERSION="$(plist_value "$IPA_INFO_PLIST" 'CFBundleShortVersionString')"
IPA_BUILD="$(plist_value "$IPA_INFO_PLIST" 'CFBundleVersion')"
IPA_BUNDLE_ID="$(plist_value "$IPA_INFO_PLIST" 'CFBundleIdentifier')"

assert_metadata_value "archive version" "$BYOT_VERSION" "$ARCHIVE_VERSION"
assert_metadata_value "archive build" "$BYOT_BUILD" "$ARCHIVE_BUILD"
assert_metadata_value "archive bundle identifier" "$BYOT_BUNDLE_ID" "$ARCHIVE_BUNDLE_ID"
assert_metadata_value "IPA version" "$BYOT_VERSION" "$IPA_VERSION"
assert_metadata_value "IPA build" "$BYOT_BUILD" "$IPA_BUILD"
assert_metadata_value "IPA bundle identifier" "$BYOT_BUNDLE_ID" "$IPA_BUNDLE_ID"
echo "Release metadata verified: $BYOT_BUNDLE_ID $BYOT_VERSION ($BYOT_BUILD)."

run_asc xcode validate \
  --ipa "$IPA_PATH" \
  "${validate_args[@]}" \
  --output json

if [[ "${BYOT_UPLOAD_TESTFLIGHT:-0}" == "1" ]]; then
  : "${ASC_APP_ID:?Set ASC_APP_ID before uploading to TestFlight.}"
  BYOT_TESTFLIGHT_GROUP="${BYOT_TESTFLIGHT_GROUP:-Internal Testers}"
  publish_args=(
    --app "$ASC_APP_ID"
    --ipa "$IPA_PATH"
    --version "$BYOT_VERSION"
    --build-number "$BYOT_BUILD"
    --group "$BYOT_TESTFLIGHT_GROUP"
    --test-notes "$(cat asc/testflight-notes.md)"
    --locale en-US
    --wait
  )
  if [[ "${BYOT_SUBMIT_BETA_REVIEW:-0}" == "1" ]]; then
    publish_args+=(--submit --confirm)
  fi
  run_asc publish testflight "${publish_args[@]}"
fi
