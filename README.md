<a href="https://www.buymeacoffee.com/zsoldier" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 60px !important;width: 217px !important;" ></a>
# mic-music-pause

Automatically **pause Apple Music when your microphone becomes active** — e.g. when
you join a Microsoft Teams, Zoom, or FaceTime call — and **resume playback when the
call ends**.

macOS gives no "call started/ended" event, so this tool watches the system
microphone state via CoreAudio (the same signal as the orange mic dot in your menu
bar). When any input device starts being used, Music is paused; when the mic is
released, Music resumes — but only if *this tool* was the one that paused it.

> Works for **any** app that uses the microphone, not just Teams.

## Menu bar toggle

The app runs as a **menu bar app** (a small music-note icon, no Dock
icon). Click it to:

- **Auto-pause music on calls** — check/uncheck to turn the behavior on or off.
- **Also pause for audio from other apps** — optional (off by default). When on,
  Music also pauses if another app (e.g. a video in your browser) starts playing
  audio, and resumes after it stops. A short quiet-period check keeps notifications
  and brief audio interruptions from resuming Music over a video.
- **Ignore audio source ▸** — submenu to exclude specific apps from triggering an
  "other-app audio" pause. Some apps (e.g. **iPhone Mirroring**) hold a silent
  audio stream open, which would otherwise cause phantom pauses; iPhone Mirroring
  (`com.apple.ScreenContinuity`) is ignored by default. The submenu lists apps
  **Currently playing** (click one to ignore it) and **Ignored** apps (checked;
  click to un-ignore). It updates live each time you open it.
- **Also pause when screen locks** — optional (off by default). When on, Music
  pauses the moment your screen locks and resumes when you unlock.
- **Only resume on external speaker** — optional (off by default). When on,
  automatic resume happens only if your current default output route is external
  (for example USB, Bluetooth, HDMI, or AirPlay). If a call ends while output is
  built-in, Music stays paused until an external route is active.
- **Start at login** — optional. Launches the app automatically when you log in
  (uses macOS Login Items).
- **Check for Updates…** — checks the repository's latest stable GitHub release
  now. The app also checks automatically at launch and every 6 hours.
- **Update available: vX.Y.Z** — click and confirm to install the update and
  restart. Direct-download installs fetch the signed DMG and verify that the
  app is trusted by macOS and matches the installed app's signing identity before
  replacing it. Homebrew installs run `brew update` and `brew upgrade` in Terminal.
  Nothing is installed without confirmation.
- **Diagnostics…** — opens a live troubleshooter window that shows all your input
  devices (naming each and its connection type, e.g. "Blue Yeti (USB)") and which
  are **ACTIVE (in use)**, which apps are currently playing audio, screen-lock
  state, whether Apple Music is running plus its Automation-permission status, and
  whether the app is currently holding a pause and why. Handy for answering
  "why did/didn't my music pause?" — a **Copy** button grabs the report for bug
  reports.
- See live status: whether you are **in a call** and the current **Music** state.
- **Quit** the app.

When auto-pause is off the icon dims; when it is actively holding a pause during a
call the icon changes to a pause symbol. macOS does not allow third-party toggles in
Control Center, so the menu bar is the native equivalent.

## Requirements

- macOS (Apple Silicon or Intel)
- Apple Music (the `Music.app` that ships with macOS).
- Xcode Command Line Tools (`xcode-select --install`) — **only** for the Homebrew
  install path, which compiles a tiny detector at install time. The direct DMG
  download below needs no developer tools.

## Download (no Homebrew, no Xcode tools)

1. Grab the latest **`mic-music-pause-<version>.dmg`** from the
   [Releases page](https://github.com/Zsoldier/mic-music-pause/releases/latest).
2. Open the DMG and drag **mic-music-pause** into **Applications**.
3. Launch it from Applications (it lives in the menu bar — no Dock icon).
4. Click the menu bar icon and enable **Start at login**.

The app is Developer ID–signed and notarized by Apple, so it opens without any
Gatekeeper warnings. Use **Check for Updates…** or click **Update available** in
the menu to install a newer release and restart. The app must be in a writable
folder, not running from the read-only DMG. Local/development builds do not offer
release updates.

## Install (Homebrew)

```sh
brew tap Zsoldier/tap
brew install mic-music-pause
open "$(brew --prefix mic-music-pause)/libexec/mic-music-pause.app"
```

Until a tagged release exists you can install the latest `main` directly:

```sh
brew install --HEAD Zsoldier/tap/mic-music-pause
open "$(brew --prefix mic-music-pause)/libexec/mic-music-pause.app"
```

Once it's running, click the menu bar icon and enable **Start at login** so it
launches automatically when you log in.

### Start at login / quitting

- **Start at login** — toggle it from the menu bar icon (uses macOS Login Items;
  no background daemon).
- **Quit** — use the menu's Quit item. It won't relaunch until you open it again
  or log in with "Start at login" enabled.
- To turn off auto-start, uncheck **Start at login** (or remove it under System
  Settings → General → Login Items).

## Install (manual, no Homebrew)

```sh
git clone https://github.com/Zsoldier/mic-music-pause.git
cd mic-music-pause
./scripts/install-local.sh
```

This builds and installs **mic-music-pause.app** in **/Applications**, installs
the CLI to `~/.local/bin`, and opens the menu bar app. No separate background
service is needed: choose **Quit** from the menu bar to stop it, then double-click
**mic-music-pause** in Applications (or find it with Spotlight) to start it again.
Enable **Start at login** in its menu if desired.

The installer removes the legacy local LaunchAgent so it no longer restarts the
app after you quit. Local builds are ad-hoc signed rather than notarized and may
ask for permission to control Music again. Installing requires write access to
/Applications. Remove the local install with `./scripts/uninstall-local.sh`
after quitting the app and disabling **Start at login**.

## Usage

The background service runs `mic-music-pause watch`. You can also run it manually:

```sh
mic-music-pause status   # show current mic + Music state
mic-music-pause once     # evaluate a single transition
mic-music-pause watch    # run the polling loop in the foreground
mic-music-pause help
```

### Configuration

| Env var           | Default                              | Purpose                       |
|-------------------|--------------------------------------|-------------------------------|
| `MIC_MUSIC_POLL`  | `2`                                  | Poll interval, seconds        |
| `MICSTATE`        | auto-detected                        | Path to the detector binary   |
| `MIC_MUSIC_STATE` | `~/.local/state/mic-music-pause`     | State directory               |

## How it works

- `src/micstate.swift` compiles to a small binary that prints `1` if **any** audio
  input device reports `kAudioDevicePropertyDeviceIsRunningSomewhere`, else `0`. Used
  by the `mic-music-pause` CLI.
- `src/menubar.swift` compiles to `mic-music-pause-menubar`, the menu bar app the
  service runs. It does the same CoreAudio detection in-process, drives `Music.app`
  via `osascript`, and exposes the on/off toggle. It only pauses if Music was
  *playing*, and only resumes if it was the one that paused — so it never hijacks
  playback you paused yourself.
- The optional "pause for audio from other apps" toggle uses CoreAudio per-process
  audio objects (`kAudioHardwarePropertyProcessObjectList` +
  `kAudioProcessPropertyIsRunningOutput`, macOS 14.2+) to see which apps are playing
  sound, ignoring Music itself. Each source is tracked independently and must stay
  active for 3 seconds to trigger a pause, so brief notification chimes cannot
  displace an ongoing video. Once all confirmed sources stop, an established
  pause is held for another 3 seconds (typically 4 seconds after detecting the
  stop with the 2-second polling interval), tolerating brief output interruptions
  before resuming.
- The optional "pause when screen locks" toggle listens for the system
  `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` notifications, so it
  pauses/resumes immediately on lock/unlock rather than waiting for the next poll.
- The optional "only resume on external speaker" toggle checks the current
  default output device transport via CoreAudio. Auto-resume is allowed on
  external routes (USB/Bluetooth/HDMI/AirPlay/etc.) and held on built-in output
  until an external route is active.
- The menu bar app checks the GitHub Releases API (unauthenticated, once at launch
  then every 6 hours, or on demand). A newer stable release with the expected DMG
  shows an "Update available" item. Installation always requires confirmation.
  Direct installs verify the DMG with Gatekeeper, check the app's code signature
  against the running app's designated signing requirement, and stage the
  replacement beside the installed app before relaunching. Homebrew-managed apps
  are updated only through Homebrew. Check/install errors are reported explicitly;
  background check failures are logged without interrupting playback.
- `bin/mic-music-pause` is a CLI for manual/headless use (`status`, `watch`, etc.).

## Notes / caveats

- Some USB speakerphones keep their mic engine running continuously. If Music pauses
  when you are *not* in a call, that device is the cause.
- The trigger is "microphone in use," so it reacts to any call app. That is by design.
- "Pause for audio from other apps" only counts apps with a bundle id, so transient
  system sounds and command-line players are ignored.

## Releasing (maintainers)

The app icon is bundled from `packaging/AppIcon.icns` for both local and signed
builds. To regenerate it after changing `scripts/generate-app-icon.swift`:

```sh
icon_work="$(mktemp -d)"
xcrun swift scripts/generate-app-icon.swift "$icon_work/AppIcon.iconset" &&
  iconutil -c icns "$icon_work/AppIcon.iconset" -o packaging/AppIcon.icns
rm -rf "$icon_work"
```

Run the audio debounce and update regression tests without launching the menu bar app:

```sh
test_binary="$(mktemp /tmp/mic-music-pause-tests.XXXXXX)"
xcrun swiftc -parse-as-library -D APP_TESTS src/menubar.swift tests/main.swift -o "$test_binary" &&
  "$test_binary"
rm -f "$test_binary"
```

Cutting a release automatically updates the formula in
[`Zsoldier/homebrew-tap`](https://github.com/Zsoldier/homebrew-tap):

```sh
./scripts/release.sh 0.1.0   # creates the v0.1.0 tag
git push origin v0.1.0       # triggers .github/workflows/release.yml
```

The workflow computes the release tarball's `sha256`, rewrites the `url` and
`sha256` in the tap formula, and pushes the change.

**One-time setup:** add a repository secret named `TAP_GITHUB_TOKEN` (Settings →
Secrets and variables → Actions) containing a GitHub token that can push to the
`homebrew-tap` repo:
- Fine-grained PAT scoped to `Zsoldier/homebrew-tap` with **Contents: Read and write**, or
- a classic PAT with the `repo` scope.

### Signed & notarized releases

The default formula ad-hoc signs the app on each machine. To ship a stable,
Developer ID-signed, notarized build (no Gatekeeper warning; Automation grant
persists across upgrades), see [`packaging/SIGNING.md`](packaging/SIGNING.md).
Requires an active Apple Developer Program membership.

## License

MIT © Chris Nakagaki
