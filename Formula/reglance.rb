# Builds the app from source, so macOS runs it without Apple notarization.
class Reglance < Formula
  desc "Floating Liquid Glass chat bar for quick questions to Claude"
  homepage "https://github.com/mrRedSun/reglance"
  url "https://github.com/mrRedSun/reglance/archive/refs/tags/v0.8.1.tar.gz"
  sha256 "adc60ebac9ead91dcd018a60aac0bfa6b4a7f368751edb61fab3efe030be8d1c"
  license "MIT"
  head "https://github.com/mrRedSun/reglance.git", branch: "main"

  depends_on macos: :tahoe

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release", "--product", "Reglance"
    app = prefix/"ReGlance.app"
    (app/"Contents/MacOS").install ".build/release/Reglance"
    (app/"Contents").install "Resources/Info.plist"
    (app/"Contents/Resources").install "Resources/AppIcon.icns"
    system "codesign", "--force", "--sign", "-", "--identifier", "app.reglance", app
  end

  def caveats
    <<~EOS
      ReGlance talks to Claude through the Claude Code CLI. Install it and log in once:
        https://code.claude.com/docs/en/setup
        claude

      Add ReGlance to Applications (once; the link survives upgrades):
        ln -sf "#{opt_prefix}/ReGlance.app" /Applications/ReGlance.app
      Or open it directly:
        open "#{opt_prefix}/ReGlance.app"

      Press Option-Space to show the chat bar.
    EOS
  end

  test do
    app = prefix/"ReGlance.app"
    assert_predicate app/"Contents/MacOS/Reglance", :executable?
    system "codesign", "--verify", "--strict", app
  end
end
