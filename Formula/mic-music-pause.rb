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
    bin.install "mic-music-pause-menubar"
  end

  service do
    run [opt_bin/"mic-music-pause-menubar"]
    keep_alive true
    log_path var/"log/mic-music-pause.log"
    error_log_path var/"log/mic-music-pause.log"
  end

  test do
    assert_match "mic-music-pause", shell_output("#{bin}/mic-music-pause help")
    assert_predicate libexec/"micstate", :executable?
    assert_predicate bin/"mic-music-pause-menubar", :executable?
  end
end
