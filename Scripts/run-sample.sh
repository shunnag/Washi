#!/bin/bash
set -euo pipefail

# 呼び出し元の作業ディレクトリに依存しない。
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sample_name="${1:-}"
case "$sample_name" in
  AppKitReader|SwiftUIReader) shift ;;
  *) echo "Usage: $0 AppKitReader|SwiftUIReader [--build-only] [--sandbox]" >&2; exit 2 ;;
esac
build_only=false
use_sandbox=false
for option in "$@"; do
  case "$option" in
    --build-only) build_only=true ;;
    --sandbox) use_sandbox=true ;;
    *) echo "Unknown option: $option" >&2; exit 2 ;;
  esac
done
sample_build="${WASHI_SAMPLE_BUILD_PATH:-$repo_root/.build/samples}"
swift build --package-path "$repo_root/Samples" --scratch-path "$sample_build" --product "$sample_name"
sample_bin="$(swift build --package-path "$repo_root/Samples" --scratch-path "$sample_build" --show-bin-path)"
sample_app="$sample_build/apps/$sample_name.app"
mkdir -p "$sample_app/Contents/MacOS" "$sample_app/Contents/Resources"
cp "$sample_bin/$sample_name" "$sample_app/Contents/MacOS/"
# アプリでは標準の Resources を使い、SwiftPM の版ごとの探索パスに依存しない。
ditto "$repo_root/Samples/Sources/ReaderSampleSupport/Resources/Demo.epub" "$sample_app/Contents/Resources/Demo.epub"
cat > "$sample_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.washi.samples.$sample_name</string>
<key>CFBundleExecutable</key><string>$sample_name</string>
<key>CFBundleName</key><string>$sample_name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if "$use_sandbox"; then
  codesign --force --sign - --entitlements "$repo_root/Samples/Sandbox.entitlements" "$sample_app"
else
  codesign --force --sign - "$sample_app"
fi
echo "$sample_app"
if ! "$build_only"; then open -n "$sample_app"; fi
