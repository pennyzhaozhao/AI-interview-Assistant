#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
ARCHIVE_PATH="${BUILD_DIR}/InterviewAssistant-macOS.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/InterviewAssistant.app"
DMG_PATH="${DIST_DIR}/InterviewAssistant.dmg"

mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_PATH}"

xcodebuild archive \
  -project "${ROOT_DIR}/InterviewAssistant.xcodeproj" \
  -scheme InterviewAssistant \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO

cat > "${BUILD_DIR}/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>export</string>
</dict></plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist"

STAGING_DIR="${BUILD_DIR}/dmg-root"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/InterviewAssistant.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create -volname "InterviewAssistant" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
echo "Created ${DMG_PATH}"
