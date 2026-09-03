cask "limitr" do
  version "1.0.1"
  sha256 "4d833a9b2b410a0553bc3c03a79a93cc853af6013d3c274f144c273984bfcadd"

  url "https://github.com/YogaEsa/limitr/releases/download/v#{version}/Limitr.app.zip"
  name "Limitr"
  desc "Menu-bar usage monitor for Claude Code and Codex CLIs"
  homepage "https://github.com/YogaEsa/limitr"

  depends_on macos: ">= :sonoma"

  app "Limitr.app"

  caveats <<~EOS
    Limitr is ad-hoc signed (no Apple Developer ID yet). If macOS blocks the
    first launch as unidentified, run:
      xattr -cr /Applications/Limitr.app
  EOS
end
