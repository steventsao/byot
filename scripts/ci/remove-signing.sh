#!/usr/bin/env bash
# Undo scripts/ci/install-signing.sh: delete the temporary keychain, the
# profiles it installed and its working directory. Safe to run more than once.
set -uo pipefail

: "${RUNNER_TEMP:?}"
SIGNING_DIR="$RUNNER_TEMP/byot-signing"
KEYCHAIN="$SIGNING_DIR/byot-signing.keychain-db"

if [[ -f "$SIGNING_DIR/selected.tsv" ]]; then
  while IFS=$'\t' read -r _ uuid _; do
    rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision" \
      "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"
  done < "$SIGNING_DIR/selected.tsv"
fi
if [[ -f "$KEYCHAIN" ]]; then
  security delete-keychain "$KEYCHAIN" || true
fi
rm -rf "$SIGNING_DIR"
