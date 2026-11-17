import Foundation

final class AudioActivityTests {
    func testNotificationDoesNotDisplaceVideo() {
        var tracker = AudioActivityTracker()
        tracker.update(sources: ["video"], now: 0)
        tracker.update(sources: ["notification", "video"], now: 2)
        tracker.update(sources: ["video"], now: 4)
        precondition(tracker.source == "video")

        tracker.update(sources: ["notification", "video"], now: 6)
        precondition(tracker.source == "video")
        tracker.update(sources: ["video"], now: 8)
        precondition(tracker.source == "video")
    }

    func testBriefAndAlternatingChimesDoNotConfirm() {
        var tracker = AudioActivityTracker()
        tracker.update(sources: ["notification"], now: 0)
        tracker.update(sources: ["notification"], now: 2)
        precondition(tracker.source == nil)
        tracker.update(sources: ["another-notification"], now: 4)
        precondition(tracker.source == nil)
        tracker.update(sources: ["notification"], now: 6)
        precondition(tracker.source == nil)
        tracker.update(sources: [], now: 8)
        precondition(tracker.source == nil)
    }

    func testBriefOutputInterruptionKeepsPause() {
        var tracker = AudioActivityTracker()
        tracker.update(sources: ["video"], now: 0)
        tracker.update(sources: ["video"], now: 4)
        tracker.update(sources: ["notification"], now: 6)
        precondition(tracker.source == "video")
        tracker.update(sources: [], now: 8)
        precondition(tracker.source == "video")
        tracker.update(sources: ["video"], now: 10)
        precondition(tracker.source == "video")
    }

    func testResumeRequiresSustainedInactivity() {
        var tracker = AudioActivityTracker()
        tracker.update(sources: ["video"], now: 0)
        tracker.update(sources: ["video"], now: 3)
        precondition(tracker.source == "video")
        tracker.update(sources: [], now: 4)
        tracker.update(sources: [], now: 6.9)
        precondition(tracker.source == "video")
        tracker.update(sources: [], now: 7)
        precondition(tracker.source == nil)

        tracker.update(sources: ["video"], now: 8)
        precondition(tracker.source == nil)
        tracker.update(sources: ["video"], now: 11)
        precondition(tracker.source == "video")
    }

    func testAnotherSustainedSourceKeepsPause() {
        var tracker = AudioActivityTracker()
        tracker.update(sources: ["video", "browser"], now: 0)
        tracker.update(sources: ["video", "browser"], now: 4)
        precondition(tracker.source != nil)
        tracker.update(sources: ["video"], now: 6)
        precondition(tracker.source == "video")
        tracker.update(sources: ["video"], now: 10)
        precondition(tracker.source == "video")
    }
}

final class AppUpdateTests {
    private let download = URL(string: "https://github.com/Zsoldier/mic-music-pause/releases/download/v1.2.3/mic-music-pause-1.2.3.dmg")!

    func testReleaseDecoding() throws {
        let json = """
        {"tag_name":"v1.2.3","draft":false,"prerelease":false,
         "assets":[{"name":"mic-music-pause-1.2.3.dmg",
                    "browser_download_url":"\(download.absoluteString)"}]}
        """
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
        precondition(release.version == "1.2.3")
        precondition(release.diskImageURL == download)
    }

    func testRejectsUnexpectedDownloads() {
        let valid = AppRelease.Asset(name: "mic-music-pause-1.2.3.dmg", browser_download_url: download)
        let wrongName = AppRelease.Asset(name: "source.zip", browser_download_url: download)
        let wrongHost = AppRelease.Asset(name: valid.name, browser_download_url: URL(string: "https://example.com/update.dmg")!)
        let wrongRepo = AppRelease.Asset(name: valid.name, browser_download_url: URL(string: "https://github.com/other/repo/releases/download/v1.2.3/mic-music-pause-1.2.3.dmg")!)
        for assets in [[], [wrongName], [wrongHost], [wrongRepo]] {
            let release = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false, assets: assets)
            precondition(release.diskImageURL == nil)
        }
    }

    func testRejectsUnstableAndMalformedReleases() {
        let asset = AppRelease.Asset(name: "mic-music-pause-1.2.3.dmg", browser_download_url: download)
        for (tag, draft, prerelease) in [
            ("v1.2.3", true, false), ("v1.2.3", false, true),
            ("v1.2.3-beta", false, false), ("../1.2.3", false, false),
            ("v1.2", false, false),
        ] {
            let release = AppRelease(tag_name: tag, draft: draft, prerelease: prerelease, assets: [asset])
            precondition(release.diskImageURL == nil)
        }
    }

    func testRejectsUnsignedApp() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("mic-music-pause-test-\(UUID().uuidString).app")
        try fm.createDirectory(at: fixture.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer {
            do { try fm.removeItem(at: fixture) }
            catch { fatalError("Test fixture cleanup failed: \(error)") }
        }
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.zsoldier.mic-music-pause",
            "CFBundleExecutable": "mic-music-pause",
            "CFBundleShortVersionString": "1.2.3",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.appendingPathComponent("Contents/MacOS/mic-music-pause"))
        do {
            try AppUpdateInstaller.validate(app: fixture, version: "1.2.3")
            preconditionFailure("An unsigned update must not be accepted")
        } catch {
            precondition(error.localizedDescription.contains("signature"))
        }
        precondition(fm.fileExists(atPath: fixture.path))
    }
}

@main
enum RegressionTestRunner {
    static func main() throws {
        let tests = AudioActivityTests()
        tests.testNotificationDoesNotDisplaceVideo()
        tests.testBriefAndAlternatingChimesDoNotConfirm()
        tests.testBriefOutputInterruptionKeepsPause()
        tests.testResumeRequiresSustainedInactivity()
        tests.testAnotherSustainedSourceKeepsPause()
        let updates = AppUpdateTests()
        try updates.testReleaseDecoding()
        updates.testRejectsUnexpectedDownloads()
        updates.testRejectsUnstableAndMalformedReleases()
        try updates.testRejectsUnsignedApp()
        print("All 9 audio activity and update regression tests passed.")
    }
}
