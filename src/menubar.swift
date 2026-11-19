import Cocoa
import CoreAudio
import ServiceManagement
import Security

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

private func defaultOutputDevice() -> AudioDeviceID? {
    var addr = prop(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
          dev != 0 else { return nil }
    return dev
}

private func isExternalOutputTransport(_ t: UInt32) -> Bool {
    switch t {
    case kAudioDeviceTransportTypeUSB,
         kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE,
         kAudioDeviceTransportTypeHDMI,
         kAudioDeviceTransportTypeDisplayPort,
         kAudioDeviceTransportTypeThunderbolt,
         kAudioDeviceTransportTypeFireWire,
         kAudioDeviceTransportTypePCI,
         kAudioDeviceTransportTypeAirPlay:
        return true
    default:
        return false
    }
}

/// True when the current default output route is an external transport
/// (USB/Bluetooth/HDMI/AirPlay/etc.), not built-in speakers.
func externalOutputConnected() -> Bool {
    guard let dev = defaultOutputDevice() else { return false }
    var addr = prop(kAudioDevicePropertyTransportType)
    var t = UInt32(0)
    var sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &t) == noErr else { return false }
    return isExternalOutputTransport(t)
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

private func processPID(_ o: AudioObjectID) -> pid_t {
    var addr = prop(kAudioProcessPropertyPID)
    var pid = pid_t(-1)
    var sz = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, &pid) == noErr else { return -1 }
    return pid
}

/// Best-effort human identity for an audio process: prefer the bundle id's app
/// name, then the running app's localized name, then the executable name, so a
/// silent background process holding an output stream is never a mystery.
private func processIdentity(_ o: AudioObjectID) -> (name: String, bundleID: String, pid: pid_t) {
    let bid = processBundleID(o)
    let pid = processPID(o)
    var name = ""
    if !bid.isEmpty { name = appName(forBundleID: bid) }
    if name.isEmpty || name == bid, pid > 0,
       let ra = NSRunningApplication(processIdentifier: pid) {
        name = ra.localizedName ?? ra.bundleURL?.deletingPathExtension().lastPathComponent ?? name
    }
    if name.isEmpty, pid > 0 {
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 {
            name = String(cString: buf)
        }
    }
    if name.isEmpty { name = bid.isEmpty ? "Unknown process" : bid }
    return (name, bid, pid)
}

/// Identity of every process that is *currently outputting* audio, excluding
/// ourselves. Includes processes with no bundle id (resolved by PID/executable
/// name) so a silent stream-holder is never hidden.
struct AudioOutputProcess {
    let name: String
    let bundleID: String
    let pid: pid_t
}

func outputtingProcesses() -> [AudioOutputProcess] {
    var out: [AudioOutputProcess] = []
    for o in audioProcessObjects() where processIsOutputting(o) {
        let id = processIdentity(o)
        if id.bundleID == selfBundleID { continue }
        out.append(AudioOutputProcess(name: id.name, bundleID: id.bundleID, pid: id.pid))
    }
    return out
}

/// The bundle ids of *other* apps (not Music, not us, not ignored) currently
/// playing audio. We require a non-empty bundle
/// id so transient system sounds and CLI helpers (e.g. afplay/notifications)
/// don't count, and skip any app the user has chosen to ignore (e.g. iPhone
/// Mirroring, which holds a silent output stream open).
/// macOS daemons that only play alert, UI and notification sounds. They report
/// a bundle id to CoreAudio and keep their output stream open for 10+ seconds
/// after a short sound, so they must never count as "another app playing audio".
let systemSoundProcesses: Set<String> = [
    "systemsoundserverd",
    "com.apple.systemsoundserverd",
    "com.apple.audio.SystemSoundServer-OSX",
]

/// Whether audio from this bundle id may trigger an "other app audio" pause.
func canTriggerAudioPause(_ bundleID: String, ignoring ignored: Set<String> = []) -> Bool {
    !bundleID.isEmpty && bundleID != "com.apple.Music"
        && !systemSoundProcesses.contains(bundleID) && !ignored.contains(bundleID)
}

func otherAudioSources(ignoring ignored: Set<String> = []) -> Set<String> {
    var sources = Set<String>()
    for p in outputtingProcesses() {
        let bid = p.bundleID
        if !canTriggerAudioPause(bid, ignoring: ignored) { continue }
        sources.insert(bid)
    }
    return sources
}

/// Apps whose audio is almost always a notification sound (chat, mail, calendar).
/// They tend to keep an output stream open for several seconds after a short
/// chime, so they must output audio for much longer before Music is paused.
/// Calls from these apps are still caught instantly by the mic check.
let notificationAudioApps: Set<String> = [
    "com.tinyspeck.slackmacgap",       // Slack
    "com.microsoft.teams2",            // Microsoft Teams
    "com.microsoft.teams",             // Microsoft Teams (classic)
    "com.microsoft.Outlook",           // Outlook
    "com.apple.MobileSMS",             // Messages
    "com.apple.mail",                  // Mail
    "com.apple.iCal",                  // Calendar
    "com.apple.reminders",             // Reminders
    "com.apple.notificationcenterui",  // Notification Center
    "com.hnc.Discord",                 // Discord
    "net.whatsapp.WhatsApp",           // WhatsApp
    "desktop.WhatsApp",                // WhatsApp (Catalyst)
    "ru.keepcoder.Telegram",           // Telegram
    "org.whispersystems.signal-desktop", // Signal
    "com.facebook.archon",             // Messenger
    "us.zoom.xos",                     // Zoom (chat chimes; calls use the mic)
    "com.webex.meetingmanager",        // Webex
    "com.readdle.smartemail-Mac",      // Spark
]

/// True when `bundleID` is a listed notification app or one of its helper
/// processes. Many chat apps play sounds from an embedded web view or helper
/// with its own bundle id (e.g. Teams uses `com.microsoft.teams2.helper`), so
/// a listed id also matches any bundle id that starts with it plus a dot.
func isNotificationAudioApp(_ bundleID: String, in apps: Set<String> = notificationAudioApps) -> Bool {
    if apps.contains(bundleID) { return true }
    return apps.contains { bundleID.hasPrefix($0 + ".") }
}

struct AudioActivityTracker {
    private var activeSince: [String: TimeInterval] = [:]
    private var inactiveSince: TimeInterval?
    private(set) var source: String?
    static let confirmSeconds = 3.0
    static let notificationConfirmSeconds = 12.0
    private let releaseSeconds = 3.0
    private let slowSources: Set<String>

    init(slowSources: Set<String> = notificationAudioApps) {
        self.slowSources = slowSources
    }

    func confirmSeconds(for source: String) -> TimeInterval {
        isNotificationAudioApp(source, in: slowSources) ? Self.notificationConfirmSeconds : Self.confirmSeconds
    }

    mutating func update(sources: Set<String>, now: TimeInterval) {
        activeSince = activeSince.filter { sources.contains($0.key) }
        for source in sources where activeSince[source] == nil {
            activeSince[source] = now
        }

        if let source = source, sources.contains(source) {
            inactiveSince = nil
            return
        }
        if let confirmed = sources.sorted().first(where: {
            now - activeSince[$0, default: now] >= confirmSeconds(for: $0)
        }) {
            source = confirmed
            inactiveSince = nil
            return
        }

        // A notification may briefly interrupt a video's output stream. Keep an
        // established pause through that gap while returning audio is confirmed.
        if source != nil {
            if inactiveSince == nil { inactiveSince = now }
            if now - (inactiveSince ?? now) >= releaseSeconds {
                source = nil
                inactiveSince = nil
            }
        }
    }
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

// MARK: - Release updates ------------------------------------------------------

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }

    var diskImageURL: URL? {
        guard !draft, !prerelease,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
        else { return nil }
        let name = "mic-music-pause-\(version).dmg"
        return assets.first {
            $0.name == name &&
            $0.browser_download_url.absoluteString ==
                "https://github.com/Zsoldier/mic-music-pause/releases/download/\(tag_name)/\(name)"
        }?.browser_download_url
    }
}

private struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppUpdateInstaller {
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
            throw UpdateFailure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(detail)")
        }
    }

    static func install(diskImage: URL, at destination: URL, version: String) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app",
              fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: destination.path) else {
            throw UpdateFailure(message: "The app cannot be replaced in its current location. Move it to a writable Applications folder, then try again.")
        }

        let mount = fm.temporaryDirectory.appendingPathComponent("mic-music-pause-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        var mounted = false
        defer {
            do {
                if mounted { try run("/usr/bin/hdiutil", ["detach", mount.path]) }
                try fm.removeItem(at: mount)
            } catch {
                NSLog("Update disk image cleanup failed at \(mount.path): \(error.localizedDescription)")
            }
        }
        try run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context",
                                   "context:primary-signature", diskImage.path])
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen",
                                    "-mountpoint", mount.path, diskImage.path])
        mounted = true

        let app = mount.appendingPathComponent("mic-music-pause.app")
        try validate(app: app, version: version)

        let staged = parent.appendingPathComponent(".mic-music-pause-update-\(UUID().uuidString).app")
        defer {
            if fm.fileExists(atPath: staged.path) {
                do { try fm.removeItem(at: staged) }
                catch { NSLog("Staged update cleanup failed: \(error.localizedDescription)") }
            }
        }
        try fm.copyItem(at: app, to: staged)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
    }

    static func validate(app: URL, version: String) throws {
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        var downloadedCode: SecStaticCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
              let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &downloadedCode) == errSecSuccess,
              let downloadedCode,
              SecStaticCodeCheckValidity(downloadedCode,
                                        SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                        requirement) == errSecSuccess else {
            throw UpdateFailure(message: "The downloaded app does not have a valid signature matching this app. No update was installed.")
        }
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "com.zsoldier.mic-music-pause",
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateFailure(message: "The downloaded app does not match the requested release.")
        }

    }
}

// MARK: - App delegate / menu bar UI --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var audioToggleItem: NSMenuItem!
    private var ignoreMenuItem: NSMenuItem!   // "Ignore audio source ▸" submenu
    private var lockToggleItem: NSMenuItem!
    private var externalResumeToggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var callInfoItem: NSMenuItem!
    private var musicInfoItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var checkUpdateItem: NSMenuItem!
    private var timer: Timer?
    private var updateTimer: Timer?

    private var diagnosticsWindow: NSWindow?
    private var diagnosticsTextView: NSTextView?
    private var diagnosticsTimer: Timer?

    private var triggerWasActive = false
    private var pausedByUs = false
    private var pauseReason = ""      // "call", "audio", or "lock" — why we're holding a pause
    private var resumeHeldForExternalOutput = false // trigger cleared, but resume is gated by output route
    private var pausedAudioApp: String?  // display name of the app that caused an audio-triggered pause
    private var audioActivity = AudioActivityTracker()
    private var screenLocked = false     // updated by screen lock/unlock notifications

    // This build's version (from Info.plist) and the latest seen on GitHub.
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var latestRelease: AppRelease?
    private var checkingForUpdate = false
    private var installingUpdate = false
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
    // Optional: auto-resume only when an external output device is the current
    // default route (off by default).
    private var resumeOnlyOnExternalOutput: Bool {
        get { defaults.object(forKey: "resumeOnlyOnExternalOutputEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "resumeOnlyOnExternalOutputEnabled") }
    }

    // Bundle ids whose audio output should NOT trigger a pause. Some apps hold a
    // silent output stream open (e.g. iPhone Mirroring), which would otherwise
    // cause phantom pauses. Seeded once with sensible defaults, then fully
    // user-managed from the "Ignore audio source" menu.
    private let defaultIgnoredAudioApps = ["com.apple.ScreenContinuity"] // iPhone Mirroring
    private var ignoredAudioApps: Set<String> {
        get {
            if !defaults.bool(forKey: "ignoredAudioAppsSeeded") {
                defaults.set(defaultIgnoredAudioApps, forKey: "ignoredAudioApps")
                defaults.set(true, forKey: "ignoredAudioAppsSeeded")
            }
            return Set(defaults.stringArray(forKey: "ignoredAudioApps") ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: "ignoredAudioApps")
            defaults.set(true, forKey: "ignoredAudioAppsSeeded")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: if an older copy is already running (e.g. after an
        // in-app upgrade relaunch), replace it so there's never a duplicate icon.
        let mypid = NSRunningApplication.current.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: selfBundleID)
            where other.processIdentifier != mypid {
            other.terminate()
        }

        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--resume-owned-pause"),
           index + 1 < arguments.count,
           musicRunning(), musicState() == "paused" {
            pausedByUs = true
            pauseReason = arguments[index + 1]
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

        // Submenu to manage which apps' audio is ignored. Populated live via
        // NSMenuDelegate so it always reflects what's currently playing.
        ignoreMenuItem = NSMenuItem(title: "Ignore audio source", action: nil, keyEquivalent: "")
        let ignoreSub = NSMenu(title: "Ignore audio source")
        ignoreSub.delegate = self
        ignoreMenuItem.submenu = ignoreSub
        menu.addItem(ignoreMenuItem)

        lockToggleItem = NSMenuItem(title: "Also pause when screen locks",
                                    action: #selector(toggleScreenLock), keyEquivalent: "")
        lockToggleItem.target = self
        lockToggleItem.state = pauseOnScreenLock ? .on : .off
        menu.addItem(lockToggleItem)

        externalResumeToggleItem = NSMenuItem(title: "Only resume on external speaker",
                              action: #selector(toggleExternalResumeGate), keyEquivalent: "")
        externalResumeToggleItem.target = self
        externalResumeToggleItem.state = resumeOnlyOnExternalOutput ? .on : .off
        menu.addItem(externalResumeToggleItem)

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

        checkUpdateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(manuallyCheckForUpdate), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

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
            resumeHeldForExternalOutput = false
        }
        NSLog("mic-music-pause auto-pause \(enabled ? "enabled" : "disabled")")
        tick()
    }

    @objc private func toggleOtherAudio() {
        pauseOnOtherAudio.toggle()
        audioToggleItem.state = pauseOnOtherAudio ? .on : .off
        audioActivity = AudioActivityTracker()
        // If turning off an audio-triggered pause (and not in a call), resume now.
        if !pauseOnOtherAudio && pausedByUs && pauseReason == "audio" && !micActive() {
            if musicRunning() { musicPlay() }
            pausedByUs = false
            resumeHeldForExternalOutput = false
        }
        NSLog("mic-music-pause pause-on-other-audio \(pauseOnOtherAudio ? "enabled" : "disabled")")
        tick()
    }

    @objc private func toggleIgnoreAudioApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String, !bid.isEmpty else { return }
        var set = ignoredAudioApps
        if set.contains(bid) {
            set.remove(bid)
            NSLog("mic-music-pause un-ignored audio app \(bid)")
        } else {
            set.insert(bid)
            NSLog("mic-music-pause ignored audio app \(bid)")
        }
        ignoredAudioApps = set
        // Reset the debounce so a now-ignored source stops counting immediately
        // (and re-evaluate right away so an unwanted pause lifts at once).
        audioActivity = AudioActivityTracker()
        tick()
    }

    @objc private func toggleScreenLock() {
        pauseOnScreenLock.toggle()
        lockToggleItem.state = pauseOnScreenLock ? .on : .off
        // If turning off a lock-triggered pause (and nothing else is active), resume.
        if !pauseOnScreenLock && pausedByUs && pauseReason == "lock" && !micActive() {
            if musicRunning() { musicPlay() }
            pausedByUs = false
            resumeHeldForExternalOutput = false
        }
        NSLog("mic-music-pause pause-on-screen-lock \(pauseOnScreenLock ? "enabled" : "disabled")")
        tick()
    }

    @objc private func toggleExternalResumeGate() {
        resumeOnlyOnExternalOutput.toggle()
        externalResumeToggleItem.state = resumeOnlyOnExternalOutput ? .on : .off
        NSLog("mic-music-pause resume-only-on-external-output \(resumeOnlyOnExternalOutput ? "enabled" : "disabled")")
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
    @objc private func manuallyCheckForUpdate() { checkForUpdate(manual: true) }

    private func showUpdateMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func checkForUpdate(manual: Bool = false) {
        guard !checkingForUpdate, !installingUpdate,
              let url = URL(string: releasesAPI) else { return }
        checkingForUpdate = true
        checkUpdateItem.title = "Checking for Updates…"
        checkUpdateItem.isEnabled = false
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("mic-music-pause", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            let result: Result<AppRelease, Error>
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200, let data else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw UpdateFailure(message: "GitHub returned HTTP \(status). Please try again later.")
                }
                let release = try JSONDecoder().decode(AppRelease.self, from: data)
                guard release.diskImageURL != nil else {
                    throw UpdateFailure(message: "The latest release does not have a supported stable macOS download yet.")
                }
                result = .success(release)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingForUpdate = false
                self.checkUpdateItem.title = "Check for Updates…"
                self.checkUpdateItem.isEnabled = !self.installingUpdate
                switch result {
                case .success(let release):
                    self.applyUpdateState(release: release)
                    if manual {
                        if self.isDevelopmentBuild(self.appVersion) {
                            self.showUpdateMessage("Development build", detail: "Release updates are disabled for local and development builds.")
                        } else if self.latestRelease != nil {
                            self.openUpdate()
                        } else {
                            self.showUpdateMessage("You’re up to date", detail: "mic-music-pause \(self.appVersion) is the latest version.")
                        }
                    }
                case .failure(let error):
                    NSLog("Update check failed: \(error.localizedDescription)")
                    if manual {
                        self.showUpdateMessage("Couldn’t check for updates", detail: error.localizedDescription)
                    }
                }
            }
        }.resume()
    }

    private func applyUpdateState(release: AppRelease) {
        latestRelease = nil
        // Local/dev builds (for example 0.0.0-local) are intentionally outside
        // release version ordering, so skip update nags for those builds.
        guard !isDevelopmentBuild(appVersion) else {
            updateItem.isHidden = true
            return
        }
        guard isNewer(release.version, than: appVersion) else {
            updateItem.isHidden = true
            return
        }
        latestRelease = release
        updateItem.title = "Update available: v\(release.version) — click to update"
        updateItem.isHidden = false
        NSLog("mic-music-pause update available: \(appVersion) -> \(release.version)")
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

    /// True for local/dev/non-release builds that should not show release update
    /// nags because semantic version comparison is not meaningful for them.
    private func isDevelopmentBuild(_ version: String) -> Bool {
        let v = version.lowercased()
        if v.hasSuffix("-local") || v.contains("local") { return true }
        if v.contains("dev") || v.contains("snapshot") || v.contains("head") { return true }
        return false
    }

    /// Direct installs replace the verified app; Homebrew remains responsible
    /// for managing its own installation.
    @objc private func openUpdate() {
        guard !installingUpdate, let release = latestRelease else { return }
        let alert = NSAlert()
        alert.messageText = "Install mic-music-pause \(release.version)?"
        alert.informativeText = "The app will update and restart. Homebrew installations are updated through Homebrew in Terminal."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Resolve symlinks so a launch via Homebrew's opt/ symlink still reveals
        // the real Cellar path. Only drive `brew upgrade` for a Homebrew install;
        // a directly-downloaded (DMG) app has no brew formula to upgrade.
        let resolvedPath = URL(fileURLWithPath: Bundle.main.bundlePath)
            .resolvingSymlinksInPath().path
        let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
        let isHomebrew = resolvedPath.contains("/Cellar/mic-music-pause/")

        guard isHomebrew else {
            installDirectUpdate(release)
            return
        }
        guard let brew = brewPath else {
            showUpdateMessage("Couldn’t start update", detail: "Homebrew was not found. Restore Homebrew and run brew upgrade zsoldier/tap/mic-music-pause.")
            return
        }

        let script = """
        #!/bin/bash
        set -euo pipefail
        trap 'rm -f -- "$0"' EXIT
        echo "Upgrading mic-music-pause…"
        "\(brew)" update
        "\(brew)" upgrade zsoldier/tap/mic-music-pause
        echo
        echo "Relaunching the app…"
        APP="$("\(brew)" --prefix mic-music-pause)/libexec/mic-music-pause.app"
        if [ ! -d "$APP" ]; then
          echo "The upgraded app was not found at $APP" >&2
          exit 1
        fi
        open -n "$APP"
        echo "Done. You can close this window."
        """
        let path = NSTemporaryDirectory() + "mic-music-pause-upgrade-\(UUID().uuidString).command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: path)
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                throw UpdateFailure(message: "Terminal could not open the Homebrew update script.")
            }
        } catch {
            NSLog("Homebrew update failed: \(error.localizedDescription)")
            showUpdateMessage("Couldn’t start update", detail: error.localizedDescription)
        }
    }

    private func installDirectUpdate(_ release: AppRelease) {
        guard let url = release.diskImageURL else { return }
        installingUpdate = true
        updateItem.title = "Downloading update…"
        updateItem.isEnabled = false
        checkUpdateItem.isEnabled = false
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let request = URLRequest(url: url, timeoutInterval: 300)
        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let temporaryURL else {
                    throw UpdateFailure(message: "The release download failed. Please try again later.")
                }
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("mic-music-pause-update-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: false)
                defer {
                    do { try fm.removeItem(at: work) }
                    catch { NSLog("Update download cleanup failed: \(error.localizedDescription)") }
                }
                let diskImage = work.appendingPathComponent("update.dmg")
                try fm.moveItem(at: temporaryURL, to: diskImage)
                DispatchQueue.main.async { self?.updateItem.title = "Installing update…" }
                try AppUpdateInstaller.install(diskImage: diskImage, at: destination, version: release.version)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateItem.title = "Update installed — restart required"
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    if self.pausedByUs {
                        configuration.arguments = ["--resume-owned-pause", self.pauseReason]
                    }
                    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                        DispatchQueue.main.async {
                            if let error {
                                self.showUpdateMessage("Update installed; restart required", detail: "Quit and reopen the app to finish updating. \(error.localizedDescription)")
                            } else {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.installingUpdate = false
                    self.updateItem.isEnabled = true
                    self.checkUpdateItem.isEnabled = true
                    self.applyUpdateState(release: release)
                    NSLog("Update installation failed: \(error.localizedDescription)")
                    self.showUpdateMessage("Couldn’t install update", detail: error.localizedDescription)
                }
            }
        }.resume()
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
        out += "  Only resume on external output: \(onoff(resumeOnlyOnExternalOutput))\n"
        out += "\n"

        out += "Audio route\n"
        if let dev = defaultOutputDevice() {
            let name = audioObjectString(dev, kAudioObjectPropertyName)
            let transport = deviceTransport(dev)
            out += "  Default output: \(name.isEmpty ? "Unnamed device" : name) (\(transport))\n"
            out += "  External route active: \(yn(externalOutputConnected()))\n"
        } else {
            out += "  Default output: unknown\n"
            out += "  External route active: no\n"
        }
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

        let procs = outputtingProcesses()
        let ignored = ignoredAudioApps
        let triggering = procs.filter { canTriggerAudioPause($0.bundleID, ignoring: ignored) }
        out += "Audio output (processes making sound)\n"
        if procs.isEmpty {
            out += "  Nothing is playing audio right now.\n"
        } else {
            for p in procs {
                let bidText = p.bundleID.isEmpty ? "no bundle id" : p.bundleID
                var tags = ""
                if p.bundleID == "com.apple.Music" { tags += "  [Apple Music]" }
                if systemSoundProcesses.contains(p.bundleID) { tags += "  [system alert sounds — won't pause]" }
                else if ignored.contains(p.bundleID) { tags += "  [IGNORED — won't pause]" }
                else if isNotificationAudioApp(p.bundleID) {
                    tags += "  [notification app — pauses only after \(Int(AudioActivityTracker.notificationConfirmSeconds))s]"
                }
                if p.bundleID.isEmpty { tags += "  [no bundle id — won't pause]" }
                out += "  ♪ \(p.name) (\(bidText), pid \(p.pid))\(tags)\n"
            }
        }
        out += "  → Would trigger a pause: \(yn(!triggering.isEmpty))"
        if let t = triggering.first { out += "  — \(t.name)" }
        out += "\n"
        if !pauseOnOtherAudio && !triggering.isEmpty {
            out += "  Note: 'pause for other-app audio' is off, so this won't trigger a pause.\n"
        }
        if !ignored.isEmpty {
            let names = ignored.sorted().map { "\(appName(forBundleID: $0)) (\($0))" }
            out += "  Ignored apps: \(names.joined(separator: ", "))\n"
            out += "  (Manage these from the menu ▸ Ignore audio source.)\n"
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
            if resumeHeldForExternalOutput {
                out += "  Holding music paused: yes — waiting for external output route before resuming.\n"
            } else {
                let why: String
                switch pauseReason {
                case "call":  why = "you're in a call"
                case "audio": why = "another app is playing audio" + (pausedAudioApp.map { " (\($0))" } ?? "")
                case "lock":  why = "the screen is locked"
                default:      why = pauseReason
                }
                out += "  Holding music paused: yes — because \(why).\n"
            }
        } else {
            out += "  Holding music paused: no.\n"
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out += "\nSnapshot: \(f.string(from: Date()))  (updates live)\n"
        return out
    }

    private func tick() {
        let canAutoResume = !resumeOnlyOnExternalOutput || externalOutputConnected()

        // Confirm each source independently so a notification cannot displace
        // sustained video audio. Debounce release as well as activation.
        let mic = micActive()
        if pauseOnOtherAudio {
            audioActivity.update(sources: otherAudioSources(ignoring: ignoredAudioApps),
                                 now: ProcessInfo.processInfo.systemUptime)
        } else {
            audioActivity = AudioActivityTracker()
        }
        let audioActiveSource = audioActivity.source
        let audioActive = audioActiveSource != nil

        let active = mic || audioActive || (pauseOnScreenLock && screenLocked)
        let reason = mic ? "call" : (audioActive ? "audio" : ((pauseOnScreenLock && screenLocked) ? "lock" : ""))

        if enabled {
            if active && !triggerWasActive {
                if musicRunning() && musicState() == "playing" {
                    musicPause(); pausedByUs = true; pauseReason = reason
                    resumeHeldForExternalOutput = false
                    // Record which app caused an audio-triggered pause so the user
                    // can see it in Diagnostics.
                    pausedAudioApp = (reason == "audio")
                        ? audioActiveSource.map { appName(forBundleID: $0) } : nil
                    NSLog("\(reason) active\(reason == "audio" ? " (\(audioActiveSource ?? "?"))" : "") -> paused Music")
                }
            } else if !active && triggerWasActive {
                if pausedByUs {
                    if canAutoResume {
                        if musicRunning() { musicPlay() }
                        pausedByUs = false
                        resumeHeldForExternalOutput = false
                        pausedAudioApp = nil
                        NSLog("trigger cleared -> resumed Music")
                    } else {
                        resumeHeldForExternalOutput = true
                        NSLog("trigger cleared but external output not active -> keeping Music paused")
                    }
                }
            } else if !active && pausedByUs && canAutoResume {
                // If a trigger cleared earlier while the external output route was
                // unavailable, resume as soon as it becomes available again.
                if musicRunning() { musicPlay() }
                pausedByUs = false
                resumeHeldForExternalOutput = false
                pausedAudioApp = nil
                NSLog("external output active -> resumed Music")
            } else if !active && pausedByUs && !canAutoResume {
                resumeHeldForExternalOutput = true
                // Keep logging sparse but explicit while we're intentionally held.
                if triggerWasActive {
                    NSLog("waiting to resume until external output route is active")
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === checkUpdateItem { return !checkingForUpdate && !installingUpdate }
        if menuItem === updateItem { return !installingUpdate }
        return true
    }
}

// MARK: - Ignore-audio submenu (live) -------------------------------------------

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === ignoreMenuItem?.submenu else { return }
        menu.removeAllItems()

        let ignored = ignoredAudioApps
        // Apps currently outputting audio that AREN'T ignored — offer to ignore.
        let playing = outputtingProcesses().filter {
            canTriggerAudioPause($0.bundleID, ignoring: ignored)
        }

        let header = NSMenuItem(title: "Check an app to stop its audio from pausing music", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let nowPlaying = NSMenuItem(title: "Currently playing", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)
        if playing.isEmpty {
            let none = NSMenuItem(title: "  (nothing else is playing)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            var seen = Set<String>()
            for p in playing where seen.insert(p.bundleID).inserted {
                let item = NSMenuItem(title: p.name, action: #selector(toggleIgnoreAudioApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.bundleID
                item.state = .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let ignoredHeader = NSMenuItem(title: "Ignored (won't pause music)", action: nil, keyEquivalent: "")
        ignoredHeader.isEnabled = false
        menu.addItem(ignoredHeader)
        if ignored.isEmpty {
            let none = NSMenuItem(title: "  (none)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for bid in ignored.sorted() {
                let item = NSMenuItem(title: appName(forBundleID: bid), action: #selector(toggleIgnoreAudioApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bid
                item.state = .on   // checked = ignored; clicking un-ignores
                menu.addItem(item)
            }
        }
    }
}

// MARK: - Entry point -----------------------------------------------------------

#if !APP_TESTS
@main
enum MenuBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
#endif
