#!/bin/bash
# Build cTerm and assemble a runnable .app bundle in dist/.
set -euo pipefail

cd "$(dirname "$0")"

# Prefer a full Xcode toolchain when one is installed: the standalone
# Command Line Tools SDK can be out of sync with its compiler on some
# macOS releases.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Keep SwiftPM and Clang caches inside the project. This avoids permission
# problems in sandboxed environments and makes builds self-contained.
mkdir -p .build/caches/module .build/caches/clang .build/caches/spm .build/caches/config .build/caches/security .build/tmp
export CLANG_MODULE_CACHE_PATH="$PWD/.build/caches/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/caches/module"
export TMPDIR="$PWD/.build/tmp"

CONFIG="${CONFIG:-release}"
APP_NAME="cTerm"
APP="dist/${APP_NAME}.app"

SWIFT_FLAGS=(--disable-sandbox
    --cache-path .build/caches/spm
    --config-path .build/caches/config
    --security-path .build/caches/security)

echo "==> Building (${CONFIG})"
swift build -c "${CONFIG}" "${SWIFT_FLAGS[@]}"

BIN="$(swift build -c "${CONFIG}" "${SWIFT_FLAGS[@]}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN}" ]]; then
    echo "error: executable not found at ${BIN}" >&2
    exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
if [[ -f Resources/cTerm.icns ]]; then
    cp Resources/cTerm.icns "${APP}/Contents/Resources/cTerm.icns"
fi
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# The Azure app (client) ID for OneDrive sync. It identifies the app, not the
# user, and is not a secret (a public client has no secret): set
# CTERM_ONEDRIVE_CLIENT_ID or put it in Resources/onedrive-client-id.txt.
CLIENT_ID="${CTERM_ONEDRIVE_CLIENT_ID:-}"
if [[ -z "${CLIENT_ID}" && -f Resources/onedrive-client-id.txt ]]; then
    CLIENT_ID="$(tr -d '[:space:]' < Resources/onedrive-client-id.txt)"
fi
if [[ -n "${CLIENT_ID}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :CTermOneDriveClientID string ${CLIENT_ID}" "${APP}/Contents/Info.plist"
else
    echo "warning: no OneDrive client ID; cloud sync will be unavailable in this build" >&2
fi

# Sign with a stable identity when there is one: an ad-hoc signature changes
# with every build, and the keychain then asks again before cTerm can read the
# key that encrypts saved credentials. Set CTERM_SIGN_IDENTITY, or create the
# local certificate once with scripts/make_signing_cert.sh.
IDENTITY="${CTERM_SIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]] && security find-certificate -c "cTerm Local Signing" >/dev/null 2>&1; then
    IDENTITY="cTerm Local Signing"
fi
if [[ -n "${IDENTITY}" ]]; then
    echo "==> Signing (${IDENTITY})"
    codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}"
else
    echo "==> Signing (ad-hoc)"
    echo "warning: no signing certificate; the keychain will ask again after each build." >&2
    echo "         Run scripts/make_signing_cert.sh once to sign with a stable identity." >&2
    codesign --force --sign - --timestamp=none "${APP}" >/dev/null 2>&1 || true
fi

echo "==> Done: ${APP}"
