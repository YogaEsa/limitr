cask "limitr" do
  version "0.0.0" # TODO: set to the tag of the first GitHub Release, e.g. "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # TODO: from `Scripts/release.sh` output

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
