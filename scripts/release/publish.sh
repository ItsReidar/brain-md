#!/usr/bin/env bash
# Publishes artifacts built by package.sh: uploads the DMG to the GitHub release v<version>
# (creating the release and tag at HEAD if needed), then renders the cask from the template
# and commits it to the Homebrew tap.
#
# Usage:
#   scripts/release/publish.sh [--version 1.2.3] [--notes-file PATH] [--tap-dir PATH] [--skip-tap | --skip-release] [--yes]
#
#   --notes-file         Markdown shown at the top of the release notes. Defaults to
#                        docs/release-notes/<version>.md when it exists.
#   --tap-dir / TAP_DIR  Local clone of ItsReidar/homebrew-tap. Defaults to the clone Homebrew
#                        made for `brew tap itsreidar/tap`, if present.
#   --skip-tap           Only publish the GitHub release.
#   --skip-release       Only update the cask in the tap (e.g. after editing the cask template),
#                        reusing the DMG already published for this version.
#   --yes                Don't ask for confirmation (for CI).
#
# Requires the GitHub CLI, authenticated: brew install gh && gh auth login
set -Eeuo pipefail

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }

version=""
tap_dir="${TAP_DIR:-}"
notes_file=""
skip_tap=false
skip_release=false
assume_yes=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --notes-file) notes_file="${2:?--notes-file needs a value}"; shift 2 ;;
        --tap-dir) tap_dir="${2:?--tap-dir needs a value}"; shift 2 ;;
        --skip-tap) skip_tap=true; shift ;;
        --skip-release) skip_release=true; shift ;;
        --yes) assume_yes=true; shift ;;
        -h|--help) usage ;;
        *) warn "unknown argument: $1"; usage 1 ;;
    esac
done

$skip_tap && $skip_release && die "--skip-tap and --skip-release together leave nothing to do"

confirm() {
    $assume_yes && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

require gh "brew install gh && gh auth login"
require curl
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated — run: gh auth login"

[[ -n "$version" ]] || version="$(project_setting MARKETING_VERSION)"
validate_version "$version"

tag="v$version"
[[ -n "$notes_file" ]] || notes_file="$REPO_ROOT/docs/release-notes/$version.md"
if [[ -f "$notes_file" ]]; then
    release_notes="$(cat "$notes_file")

---

"
elif [[ "$notes_file" == "$REPO_ROOT/docs/release-notes/$version.md" ]]; then
    release_notes=""
    warn "no release notes at ${notes_file#"$REPO_ROOT"/}; the release gets install instructions only"
else
    die "notes file not found: $notes_file"
fi
dmg="$DIST_DIR/$(dmg_name "$version")"
checksum_file="$dmg.sha256"
cask="$DIST_DIR/$CASK_NAME.rb"
for artifact in "$dmg" "$checksum_file"; do
    [[ -f "$artifact" ]] || die "missing ${artifact#"$REPO_ROOT"/} — run scripts/release/package.sh --version $version first"
done
sha256="$(awk '{print $1}' "$checksum_file")"
[[ "$(shasum -a 256 "$dmg" | awk '{print $1}')" == "$sha256" ]] || die "DMG does not match its .sha256 file"
# Always render from the committed template, so template edits reach the tap without a rebuild
# (rebuilding would produce a DMG with a different checksum than the one already published).
render_cask "$version" "$sha256" "$cask"

# The tag must point at a commit that contains exactly what was built and that GitHub knows about.
git_is_dirty && die "working tree has uncommitted changes; commit and push them before publishing"
commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
gh api "repos/$GITHUB_REPO/commits/$commit" --silent 2>/dev/null \
    || die "commit ${commit:0:12} is not on GitHub yet — push it first"

# 1. GitHub release.
if $skip_release; then
    gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
        || die "release $tag does not exist yet — publish it without --skip-release first"
    log "Skipping release upload (--skip-release); reusing the published $(basename "$dmg")"
elif gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    confirm "Release $tag exists. Replace its $(basename "$dmg") asset?" || die "aborted"
    gh release upload "$tag" "$dmg" "$checksum_file" --repo "$GITHUB_REPO" --clobber
else
    confirm "Create public GitHub release $tag at ${commit:0:12} and upload $(basename "$dmg")?" || die "aborted"
    gh release create "$tag" "$dmg" "$checksum_file" \
        --repo "$GITHUB_REPO" \
        --target "$commit" \
        --title "$DISPLAY_NAME $version" \
        --notes "${release_notes}Install with Homebrew: \`brew install --cask itsreidar/tap/$CASK_NAME\`, or download the DMG below.

$DISPLAY_NAME is signed but not notarized by Apple, so macOS blocks its first launch. Either open System Settings > Privacy & Security and click **Open Anyway**, or run \`xattr -dr com.apple.quarantine /Applications/brain-md.app\` in Terminal.

SHA-256: \`$sha256\`"
fi

# Homebrew will download from this URL; make sure it serves exactly the bytes we hashed.
url="https://github.com/$GITHUB_REPO/releases/download/$tag/$(basename "$dmg")"
log "Verifying the published download"
downloaded_sha="$(curl --fail --silent --show-error --location "$url" | shasum -a 256 | awk '{print $1}')"
[[ "$downloaded_sha" == "$sha256" ]] || die "published asset hash $downloaded_sha does not match $sha256"

# 2. Homebrew tap.
if $skip_tap; then
    log "Skipping tap update (--skip-tap)"
    exit 0
fi
if [[ -z "$tap_dir" ]] && command -v brew >/dev/null 2>&1; then
    tap_dir="$(brew --repository itsreidar/tap 2>/dev/null || true)"
fi
[[ -n "$tap_dir" && -d "$tap_dir/.git" ]] \
    || die "no tap clone found — pass --tap-dir PATH to a clone of $TAP_REPO (or --skip-tap)"

tap_cask="$tap_dir/Casks/$CASK_NAME.rb"
commit_message="chore($CASK_NAME): update cask to $version"
if git -C "$tap_dir" ls-files --error-unmatch "Casks/$CASK_NAME.rb" >/dev/null 2>&1; then
    cmp -s "$cask" "$tap_cask" && { log "Tap already has this $CASK_NAME $version cask"; exit 0; }
    grep -Fq "version \"$version\"" "$tap_cask" && commit_message="chore($CASK_NAME): refresh cask for $version"
fi
mkdir -p "$tap_dir/Casks"
cp "$cask" "$tap_cask"
git -C "$tap_dir" --no-pager diff -- "Casks/$CASK_NAME.rb" || true
confirm "Commit and push this cask to $TAP_REPO ($commit_message)?" \
    || die "aborted (the cask is copied but not committed in $tap_dir)"
git -C "$tap_dir" add "Casks/$CASK_NAME.rb"
git -C "$tap_dir" commit --quiet -m "$commit_message"
git -C "$tap_dir" push --quiet

log "Published $DISPLAY_NAME $version"
cat >&2 <<EOF

  Release  https://github.com/$GITHUB_REPO/releases/tag/$tag
  Install  brew install --cask itsreidar/tap/$CASK_NAME
  Upgrade  brew upgrade --cask $CASK_NAME
EOF
