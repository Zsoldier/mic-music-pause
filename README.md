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
  audio, and resumes when it stops.
- **Also pause when screen locks** — optional (off by default). When on, Music
  pauses the moment your screen locks and resumes when you unlock.
- **Start at login** — optional. Launches the app automatically when you log in
  (uses macOS Login Items).
- **Update available: vX.Y.Z** — appears only when a newer release exists on the
  tap. Click it to run `brew upgrade` in Terminal.
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
Gatekeeper warnings. Updates: the menu shows "Update available" when a newer
release exists and opens the Releases page so you can download the new DMG.

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

This compiles the detector, installs the script to `~/.local/bin`, and loads a
`launchd` LaunchAgent. Remove it with `./scripts/uninstall-local.sh`.

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
  sound, ignoring Music itself. A short debounce keeps brief notification chimes from
  triggering a pause.
- The optional "pause when screen locks" toggle listens for the system
  `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` notifications, so it
  pauses/resumes immediately on lock/unlock rather than waiting for the next poll.
- The menu bar app checks the GitHub Releases API (unauthenticated, once at launch
  then every 6 hours) and, if a newer version is published, shows an "Update
  available" item that runs `brew upgrade` in Terminal. `brew` remains the single
  source of truth for updates; the app only surfaces the nudge.
- `bin/mic-music-pause` is a CLI for manual/headless use (`status`, `watch`, etc.).

## Notes / caveats

- Some USB speakerphones keep their mic engine running continuously. If Music pauses
  when you are *not* in a call, that device is the cause.
- The trigger is "microphone in use," so it reacts to any call app. That is by design.
- "Pause for audio from other apps" only counts apps with a bundle id, so transient
  system sounds and command-line players are ignored.

## Releasing (maintainers)

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
