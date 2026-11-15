# Builds the app from source, so macOS runs it without Apple notarization.
class Reglance < Formula
  desc "Floating Liquid Glass chat bar for quick questions to Claude"
  homepage "https://github.com/mrRedSun/reglance"
  url "https://github.com/mrRedSun/reglance/archive/refs/tags/v0.6.0.tar.gz"
  sha256 "dda0169d96039f5034d734d83bbb54c90773d08d46ff196dae4862234433ced5"
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
