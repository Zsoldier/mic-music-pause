# TEMPLATE — future signed/notarized distribution formula.
#
# This replaces the source-compiled (ad-hoc signed) menu bar app with a
# pre-built, Developer ID-signed, NOTARIZED .app downloaded as a resource.
# The unsigned pieces (the CLI + CoreAudio detector) are still compiled from
# source, since they need no signature.
#
# To activate, once a notarized tarball is attached to the vX.Y.Z release:
#   1. Set `version` below.
#   2. Set the source `sha256` (sha256 of the source tag tarball).
#   3. Set the resource "app" `url` to the release asset and its `sha256`
#      (printed by scripts/build-signed-app.sh).
#   4. Copy this file over Formula/mic-music-pause.rb AND the tap's copy.
#
# IMPORTANT: do NOT run codesign on the downloaded .app — re-signing strips the
# notarization ticket. Install it byte-for-byte.
class MicMusicPause < Formula
  desc "Pause Apple Music while your microphone is in use, then resume"
  homepage "https://github.com/Zsoldier/mic-music-pause"
  version "0.4.0"
  url "https://github.com/Zsoldier/mic-music-pause/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/Zsoldier/mic-music-pause.git", branch: "main"

  depends_on :macos

  resource "app" do
    url "https://github.com/Zsoldier/mic-music-pause/releases/download/v0.4.0/mic-music-pause-0.4.0-macos.tar.gz"
    sha256 "REPLACE_WITH_SIGNED_APP_TARBALL_SHA256"
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
    system "/usr/sbin/stapler", "validate", libexec/"mic-music-pause.app"
  end
end
