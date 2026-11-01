#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <dmg-path> <version> <build-number>" >&2
  echo "Example: $0 dist/InterviewAssistant-1.2.0-macOS.dmg 1.2.0 4" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="$1"
VERSION="$2"
BUILD_NUMBER="$3"
APPCAST_PATH="${APPCAST_PATH:-${ROOT_DIR}/website/appcast.xml}"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 1
fi
DMG_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd)/$(basename "${DMG_PATH}")"

if [[ ! "${VERSION}" =~ '^[0-9]+([.][0-9]+)*$' ]]; then
  echo "Version must contain dot-separated numbers (for example 1.2.0)." >&2
  exit 1
fi
if [[ ! "${BUILD_NUMBER}" =~ '^[0-9]+$' ]]; then
  echo "Build number must be a positive integer." >&2
  exit 1
fi
if (( BUILD_NUMBER < 1 )); then
  echo "Build number must be greater than zero." >&2
  exit 1
fi
if [[ ! -f "${APPCAST_PATH}" ]]; then
  echo "Appcast not found: ${APPCAST_PATH}" >&2
  exit 1
fi

# sign_update reads the Sparkle private key from the developer's Keychain.
# Set SIGN_UPDATE to Sparkle's bin/sign_update from an official release, or to
# the executable in Xcode's SPM artifact cache. The common repository-local
# SPM artifact paths below are also detected automatically.
if [[ -n "${SIGN_UPDATE:-}" ]]; then
  SIGN_UPDATE_PATH="${SIGN_UPDATE}"
elif [[ -x "${ROOT_DIR}/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE_PATH="${ROOT_DIR}/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
elif [[ -x "${ROOT_DIR}/build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE_PATH="${ROOT_DIR}/build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle/bin/sign_update"
elif command -v sign_update >/dev/null 2>&1; then
  SIGN_UPDATE_PATH="$(command -v sign_update)"
else
  echo "Sparkle sign_update was not found." >&2
  echo "Set SIGN_UPDATE=/path/to/Sparkle/bin/sign_update and run this command again." >&2
  exit 1
fi

if [[ ! -x "${SIGN_UPDATE_PATH}" ]]; then
  echo "sign_update is not executable: ${SIGN_UPDATE_PATH}" >&2
  exit 1
fi

SIGNATURE_OUTPUT="$("${SIGN_UPDATE_PATH}" "${DMG_PATH}")"
ED_SIGNATURE="$(printf '%s\n' "${SIGNATURE_OUTPUT}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)"
FILE_LENGTH="$(stat -f '%z' "${DMG_PATH}")"

if [[ -z "${ED_SIGNATURE}" ]]; then
  echo "sign_update did not return a sparkle:edSignature attribute." >&2
  exit 1
fi

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

DMG_NAME="$(basename "${DMG_PATH}")"
ESCAPED_DMG_NAME="$(xml_escape "${DMG_NAME}")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="https://github.com/pennyzhaozhao/AI-interview-Assistant/releases/download/v${VERSION}/${ESCAPED_DMG_NAME}"
RELEASE_URL="https://github.com/pennyzhaozhao/AI-interview-Assistant/releases/tag/v${VERSION}"

ITEM_FILE="$(mktemp "${TMPDIR:-/tmp}/interview-ai-appcast-item.XXXXXX")"
UPDATED_APPCAST="$(mktemp "${TMPDIR:-/tmp}/interview-ai-appcast.XXXXXX")"
trap 'rm -f "${ITEM_FILE}" "${UPDATED_APPCAST}"' EXIT

cat > "${ITEM_FILE}" <<EOF
    <item>
      <title>Interview AI ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${RELEASE_URL}</sparkle:releaseNotesLink>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${FILE_LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
EOF

awk -v item_file="${ITEM_FILE}" '
  /<\/channel>/ && !inserted {
    while ((getline line < item_file) > 0) print line
    close(item_file)
    inserted = 1
  }
  { print }
  END { if (!inserted) exit 3 }
' "${APPCAST_PATH}" > "${UPDATED_APPCAST}" || {
  echo "Unable to find </channel> in ${APPCAST_PATH}." >&2
  exit 1
}

mv "${UPDATED_APPCAST}" "${APPCAST_PATH}"

echo "Added Interview AI ${VERSION} (build ${BUILD_NUMBER}) to ${APPCAST_PATH}."
echo "Next steps:"
echo "  1. Upload ${DMG_NAME} to GitHub Release v${VERSION}."
echo "  2. Commit website/appcast.xml and push it to deploy the feed."
