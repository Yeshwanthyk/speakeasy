#!/usr/bin/env bash
# Notarizes and staples a Developer ID-signed app bundle.
# Usage: script/notarize.sh <app> ; needs APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD.
set -euo pipefail

APP="${1:?app bundle required}"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

submission="$(mktemp -d "${TMPDIR:-/tmp}/speakeasy-notary.XXXXXX")"
trap 'rm -rf "$submission"' EXIT
ditto -c -k --keepParent "$APP" "$submission/Speakeasy.zip"
xcrun notarytool submit "$submission/Speakeasy.zip" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
