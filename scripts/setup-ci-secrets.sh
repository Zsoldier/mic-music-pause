#!/bin/bash
#
# One-time helper to configure the GitHub Actions secrets needed by
# .github/workflows/release.yml (Developer ID signing + notarization + tap push).
#
# Run this locally (it uses your logged-in `gh`). It prompts for the sensitive
# values so nothing is stored in shell history.
#
# Prerequisite: export your "Developer ID Application" certificate from
# Keychain Access as a .p12:
#   Keychain Access -> My Certificates -> right-click
#   "Developer ID Application: <you>" -> Export... -> .p12 (set a password).
#
# Usage:
#   ./scripts/setup-ci-secrets.sh ~/Desktop/DeveloperID.p12
#
set -euo pipefail

P12="${1:?usage: setup-ci-secrets.sh <path-to-DeveloperID.p12>}"
REPO="Zsoldier/mic-music-pause"
[ -f "$P12" ] || { echo "No such file: $P12"; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required."; exit 1; }

read -rs -p "Password you set when exporting the .p12: " P12_PW; echo
read -r  -p "Apple ID email (for notarization): " APPLE_ID
read -r  -p "Developer Team ID [U8A2AFWXCM]: " TEAM_ID
TEAM_ID="${TEAM_ID:-U8A2AFWXCM}"
read -rs -p "App-specific password (appleid.apple.com): " NOTARY_PW; echo
read -rs -p "GitHub token that can push to homebrew-tap: " TAP_TOKEN; echo

echo "==> Setting secrets on $REPO"
base64 -i "$P12" | gh secret set DEVELOPER_ID_CERT_P12      -R "$REPO"
printf '%s' "$P12_PW"    | gh secret set DEVELOPER_ID_CERT_PASSWORD -R "$REPO"
printf '%s' "$APPLE_ID"  | gh secret set NOTARY_APPLE_ID    -R "$REPO"
printf '%s' "$TEAM_ID"   | gh secret set NOTARY_TEAM_ID     -R "$REPO"
printf '%s' "$NOTARY_PW" | gh secret set NOTARY_PASSWORD    -R "$REPO"
printf '%s' "$TAP_TOKEN" | gh secret set TAP_GITHUB_TOKEN   -R "$REPO"

echo
echo "Done. Configured secrets:"
gh secret list -R "$REPO"
echo
echo "Now a release is just:"
echo "  ./scripts/release.sh 0.5.0 && git push origin v0.5.0"
echo "and the workflow signs, notarizes, publishes, and updates the tap."
