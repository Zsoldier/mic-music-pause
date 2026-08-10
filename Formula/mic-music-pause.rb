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
    sha256 "0e26816e913ac7fd86b0b5d3067cd0e1c53e59de792924fed72b61368b38ab9d"
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

  def caveats
    <<~EOS
      mic-music-pause is a menu bar app. Launch it now with:
        open "#{opt_libexec}/mic-music-pause.app"

      Then click its menu bar icon and enable "Start at login" so it launches
      automatically when you log in.
    EOS
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
