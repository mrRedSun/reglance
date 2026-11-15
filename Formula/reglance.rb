# Builds the app from source, so macOS runs it without Apple notarization.
class Reglance < Formula
  desc "Floating Liquid Glass chat bar for quick questions to Claude"
  homepage "https://github.com/mrRedSun/reglance"
  url "https://github.com/mrRedSun/reglance/archive/refs/tags/v0.4.1.tar.gz"
  sha256 "8c2c1ba342fc583ce6e6dc2fb61176e4feaf9ec38fdfb59a20224688f2c8dea4"
  license "MIT"
  head "https://github.com/mrRedSun/reglance.git", branch: "main"

  depends_on macos: :tahoe

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release", "--product", "Reglance"
    app = prefix/"Reglance.app"
    (app/"Contents/MacOS").install ".build/release/Reglance"
    (app/"Contents").install "Resources/Info.plist"
    (app/"Contents/Resources").install "Resources/AppIcon.icns"
    system "codesign", "--force", "--sign", "-", "--identifier", "app.reglance", app
  end

  def caveats
    <<~EOS
      Reglance talks to Claude through the Claude Code CLI. Install it and log in once:
        https://code.claude.com/docs/en/setup
        claude

      Add Reglance to Applications (once; the link survives upgrades):
        ln -sf "#{opt_prefix}/Reglance.app" /Applications/Reglance.app
      Or open it directly:
        open "#{opt_prefix}/Reglance.app"

      Press Option-Space to show the chat bar.
    EOS
  end

  test do
    app = prefix/"Reglance.app"
    assert_predicate app/"Contents/MacOS/Reglance", :executable?
    system "codesign", "--verify", "--strict", app
  end
end
