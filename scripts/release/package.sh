#!/usr/bin/env bash
# Builds a Release (universal) brain-md.app, signs it without an Apple Developer ID,
# packages it as a DMG and renders the Homebrew cask. Runs fully offline; nothing is published.
#
# Usage:
#   scripts/release/package.sh [--version 1.2.3] [--build-number N] [--sign-identity NAME]
#
# Signing:
#   --sign-identity / SIGN_IDENTITY  "-" (default) signs ad hoc. Pass the name of a self-signed
#                                    code-signing certificate from your keychain for a stable
#                                    identity, so macOS privacy grants survive app updates.
#
# Output (in dist/):
#   brain-md-<version>.dmg, brain-md-<version>.dmg.sha256, brain-md.rb (Homebrew cask)
set -Eeuo pipefail

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }

version=""
build_number=""
sign_identity="${SIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --build-number) build_number="${2:?--build-number needs a value}"; shift 2 ;;
        --sign-identity) sign_identity="${2:?--sign-identity needs a value}"; shift 2 ;;
        -h|--help) usage ;;
        *) warn "unknown argument: $1"; usage 1 ;;
    esac
done

for tool in xcodebuild codesign hdiutil ditto shasum lipo; do
    require "$tool" "install Xcode and its command line tools"
done

[[ -n "$version" ]] || version="$(project_setting MARKETING_VERSION)"
validate_version "$version"
[[ -n "$build_number" ]] || build_number="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "build number '$build_number' must be an integer"

if git_is_dirty; then
    warn "working tree has uncommitted changes; this build won't match any commit"
fi

if [[ "$sign_identity" != "-" ]] && ! security find-identity -p codesigning | grep -Fq "\"$sign_identity\""; then
    die "no code-signing identity named '$sign_identity' in your keychain (see docs/releasing.md)"
fi

archive="$BUILD_ROOT/brain-md.xcarchive"
build_log="$BUILD_ROOT/xcodebuild.log"
staging="$BUILD_ROOT/dmg"
dmg="$DIST_DIR/$(dmg_name "$version")"
cask="$DIST_DIR/$CASK_NAME.rb"

# Only ever delete the script's own build directory.
case "$BUILD_ROOT" in "$REPO_ROOT"/build/*) rm -rf "$BUILD_ROOT" ;; *) die "unexpected build dir: $BUILD_ROOT" ;; esac
mkdir -p "$BUILD_ROOT" "$DIST_DIR"

# 1. Archive. Xcode signs ad hoc here; the identity is applied explicitly in step 2, so the
#    exact same signing path runs for ad-hoc and certificate builds.
log "Archiving $DISPLAY_NAME $version ($build_number) — log: ${build_log#"$REPO_ROOT"/}"
if ! xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$archive" \
        -derivedDataPath "$BUILD_ROOT/DerivedData" \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        DEVELOPMENT_TEAM= \
        PROVISIONING_PROFILE_SPECIFIER= \
        >"$build_log" 2>&1; then
    tail -n 30 "$build_log" >&2
    die "xcodebuild archive failed (full log: $build_log)"
fi

app="$archive/Products/Applications/$APP_BUNDLE"
[[ -d "$app" ]] || die "archive does not contain $APP_BUNDLE"

# 2. Sign nested code inside-out, then the app. Keeps Xcode's entitlements and enables the
#    hardened runtime. No secure timestamp: Apple's timestamp service only serves Apple-issued certs.
signature_label="ad hoc"
[[ "$sign_identity" == "-" ]] || signature_label="'$sign_identity'"
log "Signing ($signature_label)"
sign() {
    codesign --force --sign "$sign_identity" --options runtime --timestamp=none \
        --preserve-metadata=entitlements "$1"
}
while IFS= read -r -d '' nested; do
    sign "$nested"
done < <(find "$app/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \
            -o -name '*.appex' -o -name '*.app' \) -print0)
sign "$app"

codesign --verify --deep --strict "$app" || die "signature verification failed"
signature_details="$(codesign --display --verbose=2 "$app" 2>&1)"
grep -q 'flags=.*runtime' <<<"$signature_details" || die "hardened runtime flag missing from signature"
archs="$(lipo -archs "$app/Contents/MacOS/brain-md")"
log "Signature OK — identifier $(awk -F= '/^Identifier=/{print $2}' <<<"$signature_details"), architectures: $archs"

# 3. DMG: the app plus an /Applications shortcut for drag-to-install.
log "Creating $(basename "$dmg")"
mkdir -p "$staging"
ditto "$app" "$staging/$APP_BUNDLE"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -ov -volname "$DISPLAY_NAME" -srcfolder "$staging" -format UDZO "$dmg"
hdiutil verify -quiet "$dmg" || die "DMG verification failed"

# 4. Checksum and cask.
sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")
render_cask "$version" "$sha256" "$cask"

log "Done"
cat >&2 <<EOF

  DMG     ${dmg#"$REPO_ROOT"/}
  SHA-256 $sha256
  Cask    ${cask#"$REPO_ROOT"/}

  Next: scripts/release/publish.sh --version $version
        (uploads the DMG to a GitHub release and updates the $TAP_REPO tap)
EOF
