# Distributes a pre-built, Developer ID-signed, NOTARIZED .app (the menu bar app),
# while compiling the unsigned CLI + CoreAudio detector from source. Do NOT
# re-sign the downloaded .app — that would strip the notarization ticket.
class MicMusicPause < Formula
  desc "Pause Apple Music while your microphone is in use, then resume"
  homepage "https://github.com/Zsoldier/mic-music-pause"
  version "0.4.0"
  url "https://github.com/Zsoldier/mic-music-pause/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "935bd5b565ba77a0b11b9c1032f176d94b7ec41f44ed6b2a35b15fe4ab7a9190"
  license "MIT"
  head "https://github.com/Zsoldier/mic-music-pause.git", branch: "main"

  depends_on :macos

  resource "app" do
    url "https://github.com/Zsoldier/mic-music-pause/releases/download/v0.4.0/mic-music-pause-0.4.0-macos.tar.gz"
    sha256 "06139bd652dce2e062232225e824bbc941c8a4b7d5474736020cd87a78f6e662"
  end

  def install
    # Unsigned pieces compiled from source (no signature required).
    system "xcrun", "swiftc", "-O", "-o", "micstate", "src/micstate.swift"
    libexec.install "micstate"
    bin.install "bin/mic-music-pause"

    # Install the pre-built, Developer ID-signed, notarized .app AS-IS.
    resource("app").stage do
      libexec.install "mic-music-pause.app"
    end

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
    # Verify the shipped app is properly signed & notarized (ticket stapled).
    system "/usr/bin/codesign", "--verify", "--strict", libexec/"mic-music-pause.app"
    system "/usr/bin/stapler", "validate", libexec/"mic-music-pause.app"
  end
end
