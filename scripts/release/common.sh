# shellcheck shell=bash
# Shared settings and helpers for the release scripts. Sourced, not executed.
# Kept compatible with the bash 3.2 that ships at /bin/bash on macOS.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly PROJECT="$REPO_ROOT/brain-md.xcodeproj"
readonly SCHEME="brain-md"
readonly APP_BUNDLE="brain-md.app"
readonly DISPLAY_NAME="Brain.md"
readonly GITHUB_REPO="ItsReidar/brain-md"
readonly TAP_REPO="ItsReidar/homebrew-tap"
readonly CASK_NAME="brain-md"
readonly BUILD_ROOT="$REPO_ROOT/build/release"
readonly DIST_DIR="$REPO_ROOT/dist"
readonly CASK_TEMPLATE="$REPO_ROOT/packaging/homebrew/$CASK_NAME.rb.template"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required${2:+ ($2)}"
}

# Prints the Release value of a build setting from the Xcode project.
project_setting() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
        | awk -v key="$1" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }'
}

validate_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "version '$1' must look like 1.2 or 1.2.3"
}

dmg_name() { printf '%s-%s.dmg' "$CASK_NAME" "$1"; }

git_is_dirty() {
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]
}
