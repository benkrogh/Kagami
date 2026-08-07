#!/bin/bash
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Kagami"
BUNDLE_ID="com.kagami.app"
BUILD_DIR="$PROJ_DIR/.build/release"
APP_BUNDLE="$PROJ_DIR/$APP_NAME.app"
ICON_ICNS="$PROJ_DIR/Resources/AppIcon/AppIcon.icns"
MODE="${1:-}"

# Default: build + install to /Applications.
# --no-install: build .app only
# --package:     build .app + zip + .pkg in dist/
# --pkg:         build .app + .pkg in dist/ (for Self Service / MDM)
NO_INSTALL=0
DO_ZIP=0
DO_PKG=0
case "$MODE" in
  --no-install) NO_INSTALL=1 ;;
  --package) NO_INSTALL=1; DO_ZIP=1; DO_PKG=1 ;;
  --pkg) NO_INSTALL=1; DO_PKG=1 ;;
  "" ) ;;
  *)
    echo "Usage: $0 [--no-install|--package|--pkg]" >&2
    exit 1
    ;;
esac

echo "🔨 Building $APP_NAME..."
cd "$PROJ_DIR"
swift build -c release 2>&1

# Ensure AppIcon.icns exists (generate from SVG if missing).
if [[ ! -f "$ICON_ICNS" ]]; then
  echo "🎨 AppIcon.icns missing — generating..."
  "$PROJ_DIR/scripts/generate-app-icon.sh"
fi

echo "📦 Assembling app bundle..."

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create directory structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy SwiftPM resource bundles into Contents/Resources (standard macOS layout).
# App code uses ResourceBundle.assets — not SwiftPM's Bundle.module — because
# Bundle.module looks for <App>.app/Kagami_Kagami.bundle (invalid next to Contents/
# and fatalErrors on other machines when the local .build fallback is missing).
mkdir -p "$APP_BUNDLE/Contents/Resources"
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        dest="$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"
        rm -rf "$dest"
        ditto "$bundle" "$dest"
        # Strip accidental nested copy of the same bundle name (stale .build artifact).
        rm -rf "$dest/$(basename "$bundle")"
    fi
done

# Copy Info.plist
cp "$PROJ_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# App icon (CFBundleIconFile = AppIcon)
cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Code sign with a stable identity when available, so macOS keeps Screen
# Recording (and other TCC) permissions across rebuilds instead of treating
# every rebuild as a brand-new app. Ad-hoc signatures embed a hash of the
# binary itself, so they change on every build and silently invalidate any
# previously granted permission — preferring a real identity here avoids that
# permission-loop entirely for local/dev installs, not just --package/--pkg.
# Preference order: dedicated local cert > real Developer ID cert > ad-hoc.
SIGN_ID="Kagami Self-Signed"
DEV_ID_APP_LOCAL="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "🔏 Signing with '$SIGN_ID'..."
    codesign --force --sign "$SIGN_ID" \
        --entitlements "$PROJ_DIR/Kagami.entitlements" \
        --timestamp=none \
        "$APP_BUNDLE"
elif [[ -n "$DEV_ID_APP_LOCAL" ]]; then
    echo "🔏 Signing with '$DEV_ID_APP_LOCAL' (stable across rebuilds)..."
    codesign --force --sign "$DEV_ID_APP_LOCAL" \
        --entitlements "$PROJ_DIR/Kagami.entitlements" \
        --timestamp=none \
        "$APP_BUNDLE"
else
    echo "🔏 Signing ad-hoc (no stable identity found — Screen Recording permission"
    echo "    will need to be re-granted after every rebuild; see README)."
    codesign --force --sign - \
        --entitlements "$PROJ_DIR/Kagami.entitlements" \
        --timestamp=none \
        "$APP_BUNDLE"
fi

echo ""
echo "✅ Done! Built at: $APP_BUNDLE"

if [[ "$DO_ZIP" -eq 1 || "$DO_PKG" -eq 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJ_DIR/Info.plist")"
    DIST_DIR="$PROJ_DIR/dist"
    mkdir -p "$DIST_DIR"

    # Look for Developer ID identities (from developer.apple.com) so distributables
    # are properly signed/notarizable instead of ad-hoc. Falls back gracefully if
    # you haven't installed them yet — see README / build.sh comments below.
    DEV_ID_APP="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
    DEV_ID_INSTALLER="$(security find-identity -v 2>/dev/null | grep '"Developer ID Installer' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
    NOTARIZE="${NOTARIZE:-0}"
    NOTARY_PROFILE="${NOTARY_PROFILE:-kagami-notary}"

    if [[ -n "$DEV_ID_APP" ]]; then
        echo ""
        echo "🔏 Re-signing for distribution with '$DEV_ID_APP' (hardened runtime)..."
        codesign --force --sign "$DEV_ID_APP" \
            --entitlements "$PROJ_DIR/Kagami.entitlements" \
            --options runtime \
            --timestamp \
            "$APP_BUNDLE"
    else
        echo ""
        echo "⚠️  No 'Developer ID Application' identity found — distributable will keep its"
        echo "    ad-hoc/self-signed signature. Recipients will see Gatekeeper warnings and"
        echo "    it cannot be notarized. Install one from developer.apple.com/account/resources/certificates,"
        echo "    then re-run. Check with: security find-identity -v -p codesigning"
    fi

    # Drop quarantine / Finder metadata so Gatekeeper only sees the download once.
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true

    # Submits $2 to Apple's notary service, then staples the resulting ticket onto $1
    # (the artifact users actually receive — .app or .pkg). Requires a keychain
    # profile stored once via:
    #   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id you@example.com --team-id TEAMID --password app-specific-password
    notarize_and_staple() {
        local target="$1" submit_path="$2"
        echo ""
        echo "📮 Submitting $(basename "$target") to Apple notary service (profile: $NOTARY_PROFILE)..."
        if xcrun notarytool submit "$submit_path" --keychain-profile "$NOTARY_PROFILE" --wait; then
            echo "📌 Stapling notarization ticket to $(basename "$target")..."
            xcrun stapler staple "$target"
        else
            echo "⚠️  Notarization failed — see log above. Distributable remains signed but unstapled."
        fi
    }

    if [[ "$DO_ZIP" -eq 1 ]]; then
        if [[ "$NOTARIZE" -eq 1 && -n "$DEV_ID_APP" ]]; then
            TMP_ZIP="$(mktemp -d)/$APP_NAME-notarize.zip"
            ditto -c -k --keepParent "$APP_BUNDLE" "$TMP_ZIP"
            notarize_and_staple "$APP_BUNDLE" "$TMP_ZIP"
            rm -f "$TMP_ZIP"
        fi
        ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
        rm -f "$ZIP_PATH"
        echo ""
        echo "📦 Packaging $ZIP_PATH..."
        ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
        echo "✅ Packaged: $ZIP_PATH"
    fi

    if [[ "$DO_PKG" -eq 1 ]]; then
        PKG_PATH="$DIST_DIR/$APP_NAME-$VERSION.pkg"
        PKG_ROOT="$DIST_DIR/pkgroot"
        PKG_SCRIPTS="$PROJ_DIR/scripts/pkg-scripts"
        rm -f "$PKG_PATH"
        rm -rf "$PKG_ROOT"
        mkdir -p "$PKG_ROOT/Applications"
        # Preserve app bundle metadata for the installer payload.
        ditto "$APP_BUNDLE" "$PKG_ROOT/Applications/$APP_NAME.app"
        chmod 755 "$PKG_SCRIPTS/preinstall"

        echo ""
        echo "📦 Building installer $PKG_PATH..."
        if [[ -n "$DEV_ID_INSTALLER" ]]; then
            UNSIGNED_PKG="$DIST_DIR/.unsigned-$APP_NAME.pkg"
            pkgbuild \
                --root "$PKG_ROOT" \
                --scripts "$PKG_SCRIPTS" \
                --identifier "$BUNDLE_ID" \
                --version "$VERSION" \
                --install-location "/" \
                "$UNSIGNED_PKG"
            echo "🔏 Signing installer with '$DEV_ID_INSTALLER'..."
            productsign --sign "$DEV_ID_INSTALLER" --timestamp "$UNSIGNED_PKG" "$PKG_PATH"
            rm -f "$UNSIGNED_PKG"
        else
            # Unsigned component package for MDM / Self Service upload.
            # IT can re-sign with "Developer ID Installer" if policy requires it:
            #   productsign --sign "Developer ID Installer: …" in.pkg out.pkg
            pkgbuild \
                --root "$PKG_ROOT" \
                --scripts "$PKG_SCRIPTS" \
                --identifier "$BUNDLE_ID" \
                --version "$VERSION" \
                --install-location "/" \
                "$PKG_PATH"
        fi
        rm -rf "$PKG_ROOT"
        echo "✅ Packaged: $PKG_PATH"

        if [[ "$NOTARIZE" -eq 1 && -n "$DEV_ID_INSTALLER" ]]; then
            notarize_and_staple "$PKG_PATH" "$PKG_PATH"
        fi

        echo ""
        if [[ -n "$DEV_ID_INSTALLER" ]]; then
            echo "Signed with Developer ID — ready to share directly with users."
            [[ "$NOTARIZE" -eq 1 ]] || echo "Tip: NOTARIZE=1 ./build.sh --pkg also notarizes + staples (removes all Gatekeeper warnings)."
        else
            echo "Hand this .pkg to IT for Self Service. It installs to /Applications."
        fi
        echo "Requires Apple Silicon (arm64) + macOS 14+."
    fi

    if [[ "$DO_ZIP" -eq 1 && "$DO_PKG" -eq 0 ]]; then
        echo ""
        if [[ -n "$DEV_ID_APP" ]]; then
            echo "Signed with Developer ID — share the zip directly with users."
        else
            echo "Share the zip internally. Recipients: unzip → Applications,"
            echo "then right-click → Open the first time (Gatekeeper)."
        fi
        echo "Requires Apple Silicon (arm64) + macOS 14+."
    fi
elif [[ "$NO_INSTALL" -eq 1 ]]; then
    echo ""
    echo "To launch Kagami:  open \"$APP_BUNDLE\""
else
    # Install to /Applications and relaunch so you're always running the latest build.
    INSTALLED="/Applications/$APP_NAME.app"
    echo ""
    echo "🚀 Installing to $INSTALLED and relaunching..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALLED"
    cp -R "$APP_BUNDLE" "$INSTALLED"
    open "$INSTALLED"
    echo "   Done — launched the freshly installed build."
fi

echo ""
echo "Note: First launch asks for Screen Recording permission once."
echo "      System Settings → Privacy & Security → Screen Recording → enable Kagami,"
echo "      then quit & reopen Kagami. The stable signature keeps it across rebuilds."
