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

// MARK: - Other-app audio output detection (CoreAudio process objects) -----------
//
// macOS 14.2+ exposes an AudioObject per process that is using audio. We list
// them and check `kAudioProcessPropertyIsRunningOutput` to see which apps are
// currently playing sound. This lets us optionally pause Music when audio starts
// coming from *another* app (e.g. a video in a browser) — using only public
// CoreAudio APIs, no private frameworks, and it works under the Hardened Runtime.

private let selfBundleID = Bundle.main.bundleIdentifier ?? "com.zsoldier.mic-music-pause"

private func audioProcessObjects() -> [AudioObjectID] {
    var addr = prop(kAudioHardwarePropertyProcessObjectList)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func processBundleID(_ o: AudioObjectID) -> String {
    var addr = prop(kAudioProcessPropertyBundleID)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(o, &addr, 0, nil, &size) == noErr, size > 0 else { return "" }
    var cf: CFString?
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, $0)
    }
    if st == noErr, let s = cf { return s as String }
    return ""
}

private func processIsOutputting(_ o: AudioObjectID) -> Bool {
    var addr = prop(kAudioProcessPropertyIsRunningOutput)
    var sz = UInt32(0)
    guard AudioObjectGetPropertyDataSize(o, &addr, 0, nil, &sz) == noErr else { return false }
    var v = UInt32(0); sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, &v) == noErr else { return false }
    return v != 0
}

/// The bundle id of some *other* app (not Music, not us) currently playing audio,
/// or nil if nothing else is. We require a non-empty bundle id so transient
/// system sounds and CLI helpers (e.g. afplay/notifications) don't count.
func otherAudioSource() -> String? {
    for o in audioProcessObjects() where processIsOutputting(o) {
        let bid = processBundleID(o)
        if bid.isEmpty || bid == "com.apple.Music" || bid == selfBundleID { continue }
        return bid
    }
    return nil
}

// MARK: - App delegate / menu bar UI --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var audioToggleItem: NSMenuItem!
    private var callInfoItem: NSMenuItem!
    private var musicInfoItem: NSMenuItem!
    private var timer: Timer?

    private var triggerWasActive = false
    private var pausedByUs = false
    private var pauseReason = ""      // "call" or "audio" — why we're holding a pause
    private var audioSeenTicks = 0    // debounce: consecutive ticks other-app audio seen

    private let defaults = UserDefaults.standard
    private var enabled: Bool {
        get { defaults.object(forKey: "autoPauseEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPauseEnabled") }
    }
    // Optional: also pause when audio starts playing from another app (default off).
    private var pauseOnOtherAudio: Bool {
        get { defaults.object(forKey: "pauseOnOtherAudioEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "pauseOnOtherAudioEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh(active: micActive())
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("mic-music-pause menu bar started (enabled=\(enabled), pauseOnOtherAudio=\(pauseOnOtherAudio))")

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

        audioToggleItem = NSMenuItem(title: "Also pause for audio from other apps",
                                     action: #selector(toggleOtherAudio), keyEquivalent: "")
        audioToggleItem.target = self
        audioToggleItem.state = pauseOnOtherAudio ? .on : .off
        menu.addItem(audioToggleItem)

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
        tick()
    }

    @objc private func toggleOtherAudio() {
        pauseOnOtherAudio.toggle()
        audioToggleItem.state = pauseOnOtherAudio ? .on : .off
        audioSeenTicks = 0
        // If turning off an audio-triggered pause (and not in a call), resume now.
        if !pauseOnOtherAudio && pausedByUs && pauseReason == "audio" && !micActive() {
            if musicRunning() { musicPlay() }
            pausedByUs = false
        }
        NSLog("mic-music-pause pause-on-other-audio \(pauseOnOtherAudio ? "enabled" : "disabled")")
        tick()
    }

    private func tick() {
        // Mic (a call) always triggers. Other-app audio triggers only when enabled,
        // and must persist for 2 ticks so brief notification sounds are ignored.
        let mic = micActive()
        var audioActive = false
        if pauseOnOtherAudio {
            if otherAudioSource() != nil { audioSeenTicks += 1 } else { audioSeenTicks = 0 }
            audioActive = audioSeenTicks >= 2
        } else {
            audioSeenTicks = 0
        }

        let active = mic || audioActive
        let reason = mic ? "call" : (audioActive ? "audio" : "")

        if enabled {
            if active && !triggerWasActive {
                if musicRunning() && musicState() == "playing" {
                    musicPause(); pausedByUs = true; pauseReason = reason
                    NSLog("\(reason) active -> paused Music")
                }
            } else if !active && triggerWasActive {
                if pausedByUs {
                    if musicRunning() { musicPlay() }
                    pausedByUs = false
                    NSLog("trigger cleared -> resumed Music")
                }
            }
        }
        triggerWasActive = active
        refresh(active: active, reason: reason)
    }

    private func refresh(active: Bool, reason: String = "") {
        guard let button = statusItem.button else { return }
        let symbol = (enabled && pausedByUs) ? "pause.circle.fill" : "music.note"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mic-music-pause")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = enabled ? 1.0 : 0.45
        button.toolTip = enabled
            ? (active ? "Music will pause" : "Idle")
            : "Auto-pause disabled"

        let label: String
        switch reason {
        case "call":  label = "● In a call"
        case "audio": label = "● Other audio playing"
        default:      label = "○ Idle"
        }
        callInfoItem?.title = label
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
