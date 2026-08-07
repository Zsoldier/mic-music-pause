# mic-music-pause

Automatically **pause Apple Music when your microphone becomes active** — e.g. when
you join a Microsoft Teams, Zoom, or FaceTime call — and **resume playback when the
call ends**.

macOS gives no "call started/ended" event, so this tool watches the system
microphone state via CoreAudio (the same signal as the orange mic dot in your menu
bar). When any input device starts being used, Music is paused; when the mic is
released, Music resumes — but only if *this tool* was the one that paused it.

> Works for **any** app that uses the microphone, not just Teams.

## Requirements

- macOS (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`) — provides `swiftc`, used at
  install time to build the tiny detector.
- Apple Music (the `Music.app` that ships with macOS).

## Install (Homebrew)

```sh
brew tap Zsoldier/tap
brew install mic-music-pause
brew services start mic-music-pause
```

Until a tagged release exists you can install the latest `main` directly:

```sh
brew install --HEAD Zsoldier/tap/mic-music-pause
brew services start mic-music-pause
```

That's it — it now runs in the background and starts again at login.

### Manage the service

```sh
brew services stop mic-music-pause     # stop
brew services restart mic-music-pause  # restart
tail -f "$(brew --prefix)/var/log/mic-music-pause.log"
```

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
  input device reports `kAudioDevicePropertyDeviceIsRunningSomewhere`, else `0`.
- `bin/mic-music-pause` polls that value and drives `Music.app` via AppleScript. It
  only pauses if Music was *playing*, and only resumes if it was the one that paused —
  so it never hijacks playback you paused yourself.

## Notes / caveats

- Some USB speakerphones keep their mic engine running continuously. If Music pauses
  when you are *not* in a call, that device is the cause.
- The trigger is "microphone in use," so it reacts to any call app. That is by design.

## License

MIT © Chris Nakagaki
