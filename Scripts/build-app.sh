#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/dist/Limitr.app"
iconset_path="$(mktemp -d)/Limitr.iconset"
icon_source="$project_root/Resources/Assets/limitr.png"
signing_identity="${CODE_SIGN_IDENTITY:--}"

trap 'rm -rf "$iconset_path"' EXIT

cd "$project_root"
build_flags=(-c release --product LimitrApp --arch arm64 --arch x86_64)
swift build "${build_flags[@]}"
bin_path="$(swift build "${build_flags[@]}" --show-bin-path)"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/LimitrApp" "$app_path/Contents/MacOS/LimitrApp"
cp "Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "Resources/Assets/gpticon.svg" "$app_path/Contents/Resources/gpticon.svg"
cp "Resources/Assets/claudeicon.svg" "$app_path/Contents/Resources/claudeicon.svg"
mkdir -p "$iconset_path"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
done
cp "$iconset_path/icon_32x32.png" "$iconset_path/icon_16x16@2x.png"
cp "$iconset_path/icon_64x64.png" "$iconset_path/icon_32x32@2x.png"
cp "$iconset_path/icon_256x256.png" "$iconset_path/icon_128x128@2x.png"
cp "$iconset_path/icon_512x512.png" "$iconset_path/icon_256x256@2x.png"
cp "$iconset_path/icon_1024x1024.png" "$iconset_path/icon_512x512@2x.png"
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/Limitr.icns"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - "$app_path"
  print "Warning: ad-hoc signature is for local testing only; do not distribute this build."
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_path"
fi

print "Built $app_path ($(lipo -archs "$app_path/Contents/MacOS/LimitrApp"))"
