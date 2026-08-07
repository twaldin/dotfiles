class SketchybarSystemStats < Formula
  desc "Simple system stats event provider for SketchyBar"
  homepage "https://github.com/joncrangle/sketchybar-system-stats"
  url "https://github.com/joncrangle/sketchybar-system-stats/releases/download/0.8.2/stats_provider-0.8.2-aarch64-apple-darwin.tar.gz"
  sha256 "e6f6230dae264224ba9e6ef59323c2c3f7234ae24e98a5a5ca1ee8a1581b92fe"
  license "GPL-3.0-only"

  def install
    bin.install "stats_provider"
  end

  test do
    system "#{bin}/stats_provider", "--version"
  end
end
