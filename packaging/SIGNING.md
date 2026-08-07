# Developer ID signing & notarization

By default the Homebrew formula compiles the menu bar app on each machine and
**ad-hoc signs** it. That works, but the signature is unique per machine, so
macOS may re-prompt for Automation permission after some upgrades, and the app
isn't notarized.

Distributing a single **Developer ID-signed, notarized** `.app` fixes both: the
signature is stable for everyone and Gatekeeper trusts it without warnings.

Because each user's `brew install` builds from source (and can't have your
private signing key), the signed app must be built **once** and distributed as a
pre-built release asset that everyone downloads.

## One-time setup (requires ACTIVE Apple Developer enrollment)

1. **Create a Developer ID Application certificate**
   - Xcode → Settings → Accounts → select your Team → *Manage Certificates…* →
     **+** → **Developer ID Application**.
   - Verify:
     ```sh
     security find-identity -v -p codesigning
     # -> "Developer ID Application: Your Name (TEAMID)"
     ```
   - Note your **Team ID** (the value in parentheses).

2. **Store notarization credentials** (creates a keychain profile named `mmp-notary`):
   ```sh
   xcrun notarytool store-credentials mmp-notary \
     --apple-id "you@example.com" \
     --team-id  "TEAMID" \
     --password "app-specific-password"
   ```
   Generate the app-specific password at <https://appleid.apple.com> →
   *Sign-In and Security* → *App-Specific Passwords*.

## Per-release steps

1. Tag the release as usual (`./scripts/release.sh 0.4.0`) and push.
2. Build + sign + notarize the app:
   ```sh
   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="mmp-notary" \
   ./scripts/build-signed-app.sh 0.4.0
   ```
   This prints the artifact path (`dist/mic-music-pause-0.4.0-macos.tar.gz`) and
   its **sha256**.
3. Attach the tarball to the GitHub release:
   ```sh
   gh release upload v0.4.0 dist/mic-music-pause-0.4.0-macos.tar.gz
   ```
4. Update the formula to the signed variant:
   - Start from `packaging/mic-music-pause-signed.rb`.
   - Fill in `version`, the source-tarball `sha256`, and the `resource "app"`
     url + sha256 (from step 2).
   - Copy over both `Formula/mic-music-pause.rb` and the tap's
     `Formula/mic-music-pause.rb`, commit, and push the tap.
5. Validate a clean install:
   ```sh
   brew uninstall mic-music-pause 2>/dev/null || true
   brew install zsoldier/tap/mic-music-pause
   codesign --verify --strict "$(brew --prefix)/opt/mic-music-pause/libexec/mic-music-pause.app"
   stapler validate "$(brew --prefix)/opt/mic-music-pause/libexec/mic-music-pause.app"
   ```
   No Gatekeeper warning should appear, and the Automation grant should persist
   across future upgrades.

## Notes

- Re-signing the downloaded `.app` (e.g. ad-hoc) **strips** the notarization
  ticket — install it byte-for-byte.
- Notarization requires the **Hardened Runtime** (`codesign --options runtime`)
  plus the `com.apple.security.automation.apple-events` entitlement (see
  `packaging/mic-music-pause.entitlements`) so the app can still control Music.
- To automate this in CI later, store the signing certificate (base64 `.p12` +
  password) and notarytool credentials as GitHub Actions secrets and run the
  same steps on a macOS runner.
