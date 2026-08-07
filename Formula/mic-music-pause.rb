class MicMusicPause < Formula
  desc "Pause Apple Music while your microphone is in use, then resume"
  homepage "https://github.com/Zsoldier/mic-music-pause"
  # Stable release — fill in the sha256 after tagging (see scripts/release.sh).
  url "https://github.com/Zsoldier/mic-music-pause/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_AFTER_TAGGING"
  license "MIT"
  head "https://github.com/Zsoldier/mic-music-pause.git", branch: "main"

  depends_on :macos

  def install
    # Compile the CoreAudio mic-state detector (used by the `mic-music-pause` CLI).
    system "xcrun", "swiftc", "-O", "-o", "micstate", "src/micstate.swift"
    # Compile the menu bar app (the background service + click-to-toggle switch).
    system "xcrun", "swiftc", "-O", "-o", "mic-music-pause-menubar", "src/menubar.swift"

    libexec.install "micstate"
    bin.install "bin/mic-music-pause"

    # Wrap the menu bar binary in a real .app bundle. This lets macOS attribute the
    # Automation permission prompt to THIS app and show the clear explanation from
    # NSAppleEventsUsageDescription (rather than a generic/unexplained request).
    app = libexec/"mic-music-pause.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/MacOS").install "mic-music-pause-menubar"
    (app/"Contents/Info.plist").write <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key><string>mic-music-pause</string>
        <key>CFBundleDisplayName</key><string>mic-music-pause</string>
        <key>CFBundleIdentifier</key><string>com.zsoldier.mic-music-pause</string>
        <key>CFBundleExecutable</key><string>mic-music-pause-menubar</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>#{version}</string>
        <key>CFBundleVersion</key><string>#{version}</string>
        <key>LSMinimumSystemVersion</key><string>11.0</string>
        <key>LSUIElement</key><true/>
        <key>NSAppleEventsUsageDescription</key>
        <string>mic-music-pause automatically pauses Apple Music when you join a call (Teams, Zoom, FaceTime, and similar) and resumes it when the call ends. To do that it needs permission to control the Music app: it only sends play and pause commands and reads whether Music is currently playing. It does not read your music library, files, messages, or any other personal data, and it never controls any other app.</string>
      </dict>
      </plist>
    PLIST

    # Ad-hoc sign so macOS can attribute the Automation grant to this bundle id.
    system "/usr/bin/codesign", "--force", "--sign", "-",
           "--identifier", "com.zsoldier.mic-music-pause", app

    # Convenience launcher on PATH that runs the binary inside the bundle
    # (so Bundle.main resolves to the .app and its Info.plist is used).
    (bin/"mic-music-pause-menubar").write <<~SH
      #!/bin/bash
      exec "#{opt_libexec}/mic-music-pause.app/Contents/MacOS/mic-music-pause-menubar" "$@"
    SH
    (bin/"mic-music-pause-menubar").chmod 0755
  end

  service do
    run [opt_libexec/"mic-music-pause.app/Contents/MacOS/mic-music-pause-menubar"]
    keep_alive true
    log_path var/"log/mic-music-pause.log"
    error_log_path var/"log/mic-music-pause.log"
  end

  test do
    assert_match "mic-music-pause", shell_output("#{bin}/mic-music-pause help")
    assert_predicate libexec/"micstate", :executable?
    assert_predicate libexec/"mic-music-pause.app/Contents/MacOS/mic-music-pause-menubar", :executable?
    assert_match "NSAppleEventsUsageDescription",
                 (libexec/"mic-music-pause.app/Contents/Info.plist").read
  end
end
