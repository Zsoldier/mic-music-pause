import Cocoa
import CoreAudio
import ServiceManagement

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

// MARK: - Diagnostics helpers ---------------------------------------------------
//
// Backing data for the "Diagnostics…" troubleshooter window: human-readable
// names for audio devices, which inputs are live, which apps are outputting,
// the Automation permission state for Music, and how this copy was installed.

private func audioObjectString(_ o: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = prop(selector)
    var cf: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, $0)
    }
    if st == noErr, let s = cf?.takeRetainedValue() { return s as String }
    return ""
}

private func deviceTransport(_ d: AudioDeviceID) -> String {
    var addr = prop(kAudioDevicePropertyTransportType)
    var t = UInt32(0)
    var sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(d, &addr, 0, nil, &sz, &t) == noErr else { return "Unknown" }
    switch t {
    case kAudioDeviceTransportTypeBuiltIn:    return "Built-in"
    case kAudioDeviceTransportTypeUSB:        return "USB"
    case kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeHDMI:       return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeFireWire:   return "FireWire"
    case kAudioDeviceTransportTypePCI:        return "PCI"
    case kAudioDeviceTransportTypeAirPlay:    return "AirPlay"
    case kAudioDeviceTransportTypeVirtual:    return "Virtual"
    case kAudioDeviceTransportTypeAggregate:  return "Aggregate"
    case kAudioDeviceTransportTypeContinuityCaptureWired,
         kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
    default:                                  return "Other"
    }
}

struct InputDeviceInfo {
    let name: String
    let transport: String
    let running: Bool
}

/// Every input-capable audio device with its name, connection type, and whether
/// it is currently in use (mic live).
func inputDeviceInfos() -> [InputDeviceInfo] {
    audioDevices().filter { hasInput($0) }.map { d in
        var name = audioObjectString(d, kAudioObjectPropertyName)
        if name.isEmpty { name = "Unnamed device" }
        return InputDeviceInfo(name: name, transport: deviceTransport(d), running: isRunning(d))
    }
}

/// Friendly app name for a bundle id, falling back to the id itself.
func appName(forBundleID bid: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
        let n = FileManager.default.displayName(atPath: url.path)
        if !n.isEmpty { return n.hasSuffix(".app") ? String(n.dropLast(4)) : n }
    }
    return bid
}

/// Bundle ids of every app (except us) currently outputting audio.
func outputtingApps() -> [String] {
    var out: [String] = []
    for o in audioProcessObjects() where processIsOutputting(o) {
        let bid = processBundleID(o)
        if bid.isEmpty || bid == selfBundleID { continue }
        out.append(bid)
    }
    return out
}

/// Automation (Apple Events) permission state for controlling Music.
func musicAutomationPermission() -> String {
    guard musicRunning() else { return "Unknown — Music isn't running" }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
    guard let ae = target.aeDesc else { return "Unknown" }
    let status = AEDeterminePermissionToAutomateTarget(ae, typeWildCard, typeWildCard, false)
    switch status {
    case noErr:
        return "Granted"
    case OSStatus(errAEEventNotPermitted):
        return "Denied — turn on under System Settings ▸ Privacy & Security ▸ Automation"
    case OSStatus(errAEEventWouldRequireUserConsent):
        return "Not yet granted — you'll be asked the first time music is paused"
    case OSStatus(procNotFound):
        return "Unknown — Music isn't running"
    default:
        return "Unknown (status \(status))"
    }
}

/// How this build was installed, for support triage.
func installSource() -> String {
    let resolved = URL(fileURLWithPath: Bundle.main.bundlePath).resolvingSymlinksInPath().path
    if resolved.contains("/Cellar/mic-music-pause/") { return "Homebrew" }
    if resolved.hasPrefix("/Applications/") { return "Direct download (DMG)" }
    return "Other — \(resolved)"
}

// MARK: - App delegate / menu bar UI --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var audioToggleItem: NSMenuItem!
    private var lockToggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var callInfoItem: NSMenuItem!
    private var musicInfoItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var timer: Timer?
    private var updateTimer: Timer?

    private var diagnosticsWindow: NSWindow?
    private var diagnosticsTextView: NSTextView?
    private var diagnosticsTimer: Timer?

    private var triggerWasActive = false
    private var pausedByUs = false
    private var pauseReason = ""      // "call", "audio", or "lock" — why we're holding a pause
    private var audioActiveSince: Date?  // when the current other-app audio source was first seen (debounce)
    private var audioActiveSource: String?  // bundle id of that source; a change restarts the debounce
    private let audioConfirmSeconds = 3.0 // the SAME source must play this long to pause (rejects notification dings)
    private var screenLocked = false     // updated by screen lock/unlock notifications

    // This build's version (from Info.plist) and the latest seen on GitHub.
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var latestVersion: String?
    private let releasesAPI = "https://api.github.com/repos/Zsoldier/mic-music-pause/releases/latest"

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
    // Optional: also pause when the screen locks, resume on unlock (default off).
    private var pauseOnScreenLock: Bool {
        get { defaults.object(forKey: "pauseOnScreenLockEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "pauseOnScreenLockEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: if an older copy is already running (e.g. after an
        // in-app upgrade relaunch), replace it so there's never a duplicate icon.
        let mypid = NSRunningApplication.current.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: selfBundleID)
            where other.processIdentifier != mypid {
            other.terminate()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh(active: micActive())

        // If "start at login" is on, re-register so the recorded launch path
        // stays correct after a Homebrew upgrade moved the app bundle.
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Screen lock/unlock are delivered as distributed notifications; observe
        // them so we can pause/resume immediately rather than waiting for the poll.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onScreenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        NSLog("mic-music-pause menu bar started (enabled=\(enabled), pauseOnOtherAudio=\(pauseOnOtherAudio), pauseOnScreenLock=\(pauseOnScreenLock))")

        // Check for a newer release shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkForUpdate() }
        let ut = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        RunLoop.main.add(ut, forMode: .common)
        updateTimer = ut

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

        lockToggleItem = NSMenuItem(title: "Also pause when screen locks",
                                    action: #selector(toggleScreenLock), keyEquivalent: "")
        lockToggleItem.target = self
        lockToggleItem.state = pauseOnScreenLock ? .on : .off
        menu.addItem(lockToggleItem)

        if #available(macOS 13.0, *) {
            loginItem = NSMenuItem(title: "Start at login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())

        callInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        callInfoItem.isEnabled = false
        menu.addItem(callInfoItem)

        musicInfoItem = NSMenuItem(title: "Music: —", action: nil, keyEquivalent: "")
        musicInfoItem.isEnabled = false
        menu.addItem(musicInfoItem)

        updateItem = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true   // shown only when a newer release is found
        menu.addItem(updateItem)

        let diagnostics = NSMenuItem(title: "Diagnostics…",
                                     action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

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
        audioActiveSince = nil
        audioActiveSource = nil
        // If turning off an audio-triggered pause (and not in a call), resume now.
        if !pauseOnOtherAudio && pausedByUs && pauseReason == "audio" && !micActive() {
            if musicRunning() { musicPlay() }
            pausedByUs = false
        }
        NSLog("mic-music-pause pause-on-other-audio \(pauseOnOtherAudio ? "enabled" : "disabled")")
        tick()
    }

    @objc private func toggleScreenLock() {
        pauseOnScreenLock.toggle()
        lockToggleItem.state = pauseOnScreenLock ? .on : .off
        // If turning off a lock-triggered pause (and nothing else is active), resume.
        if !pauseOnScreenLock && pausedByUs && pauseReason == "lock" && !micActive() {
            if musicRunning() { musicPlay() }
            pausedByUs = false
        }
        NSLog("mic-music-pause pause-on-screen-lock \(pauseOnScreenLock ? "enabled" : "disabled")")
        tick()
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("mic-music-pause start-at-login toggle failed: \(error.localizedDescription)")
            // Surface the failure so the user isn't left with a wrong checkmark.
            let alert = NSAlert()
            alert.messageText = "Couldn't change \u{201C}Start at login\u{201D}"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        NSLog("mic-music-pause start-at-login \(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")")
    }

    @objc private func onScreenLocked() {
        screenLocked = true
        tick()
    }

    @objc private func onScreenUnlocked() {
        screenLocked = false
        tick()
    }

    // MARK: - Update checking

    /// Fetch the latest release tag from GitHub and, if it's newer than this
    /// build, reveal the "Update available" menu item. Network only; no auth.
    private func checkForUpdate() {
        guard let url = URL(string: releasesAPI) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("mic-music-pause", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async { self.applyUpdateState(latest: latest) }
        }.resume()
    }

    private func applyUpdateState(latest: String) {
        guard isNewer(latest, than: appVersion) else {
            updateItem.isHidden = true
            return
        }
        latestVersion = latest
        updateItem.title = "Update available: v\(latest) — click to update"
        updateItem.isHidden = false
        NSLog("mic-music-pause update available: \(appVersion) -> \(latest)")
    }

    /// Compare dotted version strings numerically (e.g. "0.10.0" > "0.9.0").
    /// Non-numeric suffixes (like "-test") are ignored per component.
    private func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Run `brew upgrade` in Terminal via a throwaway .command file. Opening the
    /// file launches Terminal independently, so it survives brew restarting our
    /// service, and it needs no extra automation permission.
    @objc private func openUpdate() {
        let releasesPage = URL(string: "https://github.com/Zsoldier/mic-music-pause/releases/latest")!

        // Resolve symlinks so a launch via Homebrew's opt/ symlink still reveals
        // the real Cellar path. Only drive `brew upgrade` for a Homebrew install;
        // a directly-downloaded (DMG) app has no brew formula to upgrade.
        let resolvedPath = URL(fileURLWithPath: Bundle.main.bundlePath)
            .resolvingSymlinksInPath().path
        let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
        let isHomebrew = resolvedPath.contains("/Cellar/mic-music-pause/") && brewPath != nil

        guard isHomebrew, let brew = brewPath else {
            // Direct download: send the user to the Releases page to grab the
            // latest DMG.
            NSWorkspace.shared.open(releasesPage)
            return
        }

        let script = """
        #!/bin/bash
        echo "Upgrading mic-music-pause…"
        "\(brew)" upgrade zsoldier/tap/mic-music-pause
        echo
        echo "Relaunching the app…"
        APP="$("\(brew)" --prefix mic-music-pause)/libexec/mic-music-pause.app"
        [ -d "$APP" ] && open -n "$APP"
        echo "Done. You can close this window."
        """
        let path = NSTemporaryDirectory() + "mic-music-pause-upgrade.command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            // Fallback: open the releases page so the user can update manually.
            NSWorkspace.shared.open(releasesPage)
        }
    }

    // MARK: Diagnostics window (troubleshooter)

    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "mic-music-pause — Diagnostics"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = NSSize(width: 420, height: 320)

            let content = NSView(frame: w.contentView!.bounds)
            content.autoresizingMask = [.width, .height]

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 560, height: 436))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let tv = NSTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width]
            tv.isEditable = false
            tv.isRichText = false
            tv.drawsBackground = true
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 10, height: 10)
            scroll.documentView = tv
            diagnosticsTextView = tv

            let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyDiagnostics))
            copyBtn.frame = NSRect(x: 12, y: 8, width: 120, height: 28)
            copyBtn.bezelStyle = .rounded
            copyBtn.autoresizingMask = [.maxXMargin, .maxYMargin]

            let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshDiagnostics))
            refreshBtn.frame = NSRect(x: 560 - 132, y: 8, width: 120, height: 28)
            refreshBtn.bezelStyle = .rounded
            refreshBtn.autoresizingMask = [.minXMargin, .maxYMargin]

            content.addSubview(scroll)
            content.addSubview(copyBtn)
            content.addSubview(refreshBtn)
            w.contentView = content
            w.center()
            diagnosticsWindow = w
        }

        // (Re)start the live-refresh timer — it's torn down when the window
        // closes, so reopening needs a fresh one.
        if diagnosticsTimer == nil {
            let dt = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.updateDiagnosticsText()
            }
            RunLoop.main.add(dt, forMode: .common)
            diagnosticsTimer = dt
        }
        updateDiagnosticsText()
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshDiagnostics() { updateDiagnosticsText() }

    @objc private func copyDiagnostics() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnosticsReport(), forType: .string)
    }

    private func updateDiagnosticsText() {
        diagnosticsTextView?.string = diagnosticsReport()
    }

    private func diagnosticsReport() -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        func onoff(_ b: Bool) -> String { b ? "ON" : "off" }

        var out = ""
        out += "mic-music-pause — diagnostics\n"
        out += "=============================\n"
        out += "Version:        \(appVersion)\n"
        out += "Installed via:  \(installSource())\n"
        if #available(macOS 13.0, *) {
            out += "Start at login: \(onoff(SMAppService.mainApp.status == .enabled))\n"
        }
        out += "\n"

        out += "Settings\n"
        out += "  Auto-pause on calls:            \(onoff(enabled))\n"
        out += "  Also pause for other-app audio: \(onoff(pauseOnOtherAudio))\n"
        out += "  Also pause when screen locks:   \(onoff(pauseOnScreenLock))\n"
        out += "\n"

        let inputs = inputDeviceInfos()
        let activeInputs = inputs.filter { $0.running }
        out += "Microphone / input devices\n"
        if inputs.isEmpty {
            out += "  (no input devices found)\n"
        } else {
            for d in inputs {
                let mark = d.running ? "● ACTIVE (in use)" : "○ idle"
                out += "  \(mark)  \(d.name) (\(d.transport))\n"
            }
        }
        out += "  → Call detected (a mic is in use): \(yn(!activeInputs.isEmpty))"
        if let first = activeInputs.first {
            out += "  — \(first.name) (\(first.transport))"
        }
        out += "\n\n"

        let outputting = outputtingApps()
        let others = outputting.filter { $0 != "com.apple.Music" }
        out += "Audio output (other apps)\n"
        if outputting.isEmpty {
            out += "  Nothing is playing audio right now.\n"
        } else {
            for bid in outputting {
                let tag = bid == "com.apple.Music" ? "  [Apple Music]" : ""
                out += "  ♪ \(appName(forBundleID: bid)) (\(bid))\(tag)\n"
            }
        }
        if !pauseOnOtherAudio && !others.isEmpty {
            out += "  Note: 'pause for other-app audio' is off, so this won't trigger a pause.\n"
        }
        out += "\n"

        out += "Screen\n"
        out += "  Locked: \(yn(screenLocked))\n"
        out += "\n"

        out += "Apple Music\n"
        let running = musicRunning()
        out += "  Running:               \(yn(running))\n"
        out += "  Player state:          \(running ? (musicState().isEmpty ? "unknown" : musicState()) : "not running")\n"
        out += "  Automation permission: \(musicAutomationPermission())\n"
        out += "\n"

        out += "Current status\n"
        if pausedByUs {
            let why: String
            switch pauseReason {
            case "call":  why = "you're in a call"
            case "audio": why = "another app is playing audio"
            case "lock":  why = "the screen is locked"
            default:      why = pauseReason
            }
            out += "  Holding music paused: yes — because \(why).\n"
        } else {
            out += "  Holding music paused: no.\n"
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out += "\nSnapshot: \(f.string(from: Date()))  (updates live)\n"
        return out
    }

    private func tick() {
        // Mic (a call) always triggers. Other-app audio triggers only when enabled,
        // and the SAME source must keep playing for `audioConfirmSeconds` so brief
        // notification dings (which don't sustain that long) are ignored. Resume,
        // however, happens on the very next poll once audio clears.
        let mic = micActive()
        var audioActive = false
        if pauseOnOtherAudio {
            if let src = otherAudioSource() {
                // A new/changed source restarts the confirmation window, so a short
                // ding from one app can't add its time to unrelated blips from
                // another — only genuinely sustained playback from one source counts.
                if src != audioActiveSource {
                    audioActiveSource = src
                    audioActiveSince = Date()
                }
                audioActive = Date().timeIntervalSince(audioActiveSince ?? Date()) >= audioConfirmSeconds
            } else {
                audioActiveSince = nil
                audioActiveSource = nil
            }
        } else {
            audioActiveSince = nil
            audioActiveSource = nil
        }

        let active = mic || audioActive || (pauseOnScreenLock && screenLocked)
        let reason = mic ? "call" : (audioActive ? "audio" : ((pauseOnScreenLock && screenLocked) ? "lock" : ""))

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
        case "lock":  label = "● Screen locked"
        default:      label = "○ Idle"
        }
        callInfoItem?.title = label
        let state = musicRunning() ? musicState() : "not running"
        musicInfoItem?.title = "Music: \(state.isEmpty ? "unknown" : state)"
    }
}

// MARK: - Diagnostics window lifecycle ------------------------------------------

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === diagnosticsWindow else { return }
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }
}

// MARK: - Entry point -----------------------------------------------------------

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
