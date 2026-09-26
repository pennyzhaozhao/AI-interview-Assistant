#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
ARCHIVE_PATH="${BUILD_DIR}/InterviewAssistant-macOS.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
STAGING_DIR="${BUILD_DIR}/dmg-root"
ENTITLEMENTS_PATH="${ROOT_DIR}/InterviewAssistant/Resources/InterviewAssistant.entitlements"
SIGNED_RELEASE="${SIGNED_RELEASE:-0}"

VERSION="$(xcodebuild \
  -project "${ROOT_DIR}/InterviewAssistant.xcodeproj" \
  -scheme InterviewAssistant \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -showBuildSettings | awk '/MARKETING_VERSION/ { print $3; exit }')"

if [[ -z "${VERSION}" ]]; then
  echo "Unable to read MARKETING_VERSION" >&2
  exit 1
fi

DMG_PATH="${DIST_DIR}/InterviewAssistant-${VERSION}-macOS.dmg"

mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${STAGING_DIR}" "${DMG_PATH}"

if [[ "${SIGNED_RELEASE}" == "1" ]]; then
  echo "Building a Developer ID signed archive..."
  xcodebuild archive \
    -project "${ROOT_DIR}/InterviewAssistant.xcodeproj" \
    -scheme InterviewAssistant \
    -configuration Release \
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
else
  echo "No Developer ID release requested; building an ad-hoc signed preview..."
  xcodebuild archive \
    -project "${ROOT_DIR}/InterviewAssistant.xcodeproj" \
    -scheme InterviewAssistant \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    SKIP_INSTALL=NO \
    CODE_SIGNING_ALLOWED=NO

  mkdir -p "${EXPORT_DIR}"
  cp -R "${ARCHIVE_PATH}/Products/Applications/InterviewAssistant.app" "${EXPORT_DIR}/InterviewAssistant.app"
  codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "${ENTITLEMENTS_PATH}" \
    "${EXPORT_DIR}/InterviewAssistant.app"
fi

APP_PATH="${EXPORT_DIR}/InterviewAssistant.app"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/InterviewAssistant.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "InterviewAssistant" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "Created ${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"
