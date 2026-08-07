import Cocoa
import CoreAudio

// MARK: - Microphone detection (CoreAudio) --------------------------------------

private func prop(_ sel: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func audioDevices() -> [AudioDeviceID] {
    var addr = prop(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let n = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: n)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

private func hasInput(_ d: AudioDeviceID) -> Bool {
    var addr = prop(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size)
    if size == 0 { return false }
    let bl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
    defer { bl.deallocate() }
    AudioObjectGetPropertyData(d, &addr, 0, nil, &size, bl)
    var ch = 0
    for b in UnsafeMutableAudioBufferListPointer(bl) { ch += Int(b.mNumberChannels) }
    return ch > 0
}

private func isRunning(_ d: AudioDeviceID) -> Bool {
    var addr = prop(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var r = UInt32(0); var s = UInt32(4)
    AudioObjectGetPropertyData(d, &addr, 0, nil, &s, &r)
    return r != 0
}

/// True if any input device's microphone is currently in use.
func micActive() -> Bool {
    audioDevices().contains { hasInput($0) && isRunning($0) }
}

// MARK: - Apple Music control ---------------------------------------------------
//
// We talk to Music with Apple Events sent *in-process* (NSAppleScript) so macOS
// attributes the Automation permission prompt to THIS app and shows our
// NSAppleEventsUsageDescription. Whether Music is running is checked via
// NSWorkspace, which needs no permission at all — so the only consent prompt the
// user ever sees is a single, clearly-explained request to control Music.

private func musicRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
}

@discardableResult
private func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let result = script.executeAndReturnError(&error)
    if let error = error {
        NSLog("AppleScript error: \(error[NSAppleScript.errorMessage] ?? error)")
        return nil
    }
    return result.stringValue
}

// NOTE: only call these when musicRunning() is true — "tell application \"Music\""
// would otherwise launch Music.
private func musicState() -> String { runAppleScript(#"tell application "Music" to player state as string"#) ?? "" }
private func musicPause() { runAppleScript(#"tell application "Music" to pause"#) }
private func musicPlay()  { runAppleScript(#"tell application "Music" to play"#) }

// MARK: - App delegate / menu bar UI --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var callInfoItem: NSMenuItem!
    private var musicInfoItem: NSMenuItem!
    private var timer: Timer?

    private var micWasActive = false
    private var pausedByUs = false

    private let defaults = UserDefaults.standard
    private var enabled: Bool {
        get { defaults.object(forKey: "autoPauseEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPauseEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh(active: micActive())
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("mic-music-pause menu bar started (enabled=\(enabled))")

        // Prime the Automation permission prompt now (with our clear explanation)
        // instead of surprising the user mid-call. Only if Music is already running
        // so we never launch it just to ask.
        if musicRunning() {
            DispatchQueue.global().async { _ = musicState() }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Auto-pause music on calls",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = enabled ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        callInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        callInfoItem.isEnabled = false
        menu.addItem(callInfoItem)

        musicInfoItem = NSMenuItem(title: "Music: —", action: nil, keyEquivalent: "")
        musicInfoItem.isEnabled = false
        menu.addItem(musicInfoItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
        // If turning off while we're holding a pause, let playback resume.
        if !enabled && pausedByUs {
            if musicRunning() { musicPlay() }
            pausedByUs = false
        }
        NSLog("mic-music-pause auto-pause \(enabled ? "enabled" : "disabled")")
        refresh(active: micWasActive)
    }

    private func tick() {
        let active = micActive()
        if enabled {
            if active && !micWasActive {
                if musicRunning() && musicState() == "playing" {
                    musicPause(); pausedByUs = true
                    NSLog("mic active -> paused Music")
                }
            } else if !active && micWasActive {
                if pausedByUs {
                    if musicRunning() { musicPlay() }
                    pausedByUs = false
                    NSLog("mic released -> resumed Music")
                }
            }
        }
        micWasActive = active
        refresh(active: active)
    }

    private func refresh(active: Bool) {
        guard let button = statusItem.button else { return }
        let symbol = (enabled && pausedByUs) ? "pause.circle.fill" : "music.note"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mic-music-pause")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = enabled ? 1.0 : 0.45
        button.toolTip = enabled
            ? (active ? "In a call — music will pause" : "Idle")
            : "Auto-pause disabled"

        callInfoItem?.title = active ? "● In a call" : "○ Idle"
        let state = musicRunning() ? musicState() : "not running"
        musicInfoItem?.title = "Music: \(state.isEmpty ? "unknown" : state)"
    }
}

// MARK: - Entry point -----------------------------------------------------------

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
