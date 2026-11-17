#!/bin/zsh
# Releases a version: bumps Resources/Info.plist, commits "Release <version>: <summary>",
# tags v<version> and pushes, then points Formula/reglance.rb at the tag's tarball and
# commits "Set formula checksum for v<version>". Homebrew builds from that tarball.
#
#   scripts/release.sh 0.8.0 "nerd stats"            release
#   scripts/release.sh --dry-run 0.8.0 "nerd stats"  print what would happen
set -euo pipefail

cd "${0:A:h}/.."

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi
VERSION="${1:-}"
SUMMARY="${2:-}"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "usage: scripts/release.sh [--dry-run] <major.minor.patch> [summary]" >&2
    exit 1
fi
TAG="v$VERSION"
MESSAGE="Release $VERSION${SUMMARY:+: $SUMMARY}"
PLIST="Resources/Info.plist"
FORMULA="Formula/reglance.rb"
REPO_URL="$(sed -n 's/^  homepage "\(.*\)"$/\1/p' "$FORMULA")"
TARBALL="$REPO_URL/archive/refs/tags/$TAG.tar.gz"

# Runs a command, or prints it in a dry run.
run() {
    if $DRY_RUN; then echo "+ ${(q)@}"; else "$@"; fi
}

# A dry run reports these problems but carries on, so it can be tried from any branch.
fail() {
    echo "$1" >&2
    $DRY_RUN || exit 1
}

[[ -n "$REPO_URL" ]] || { echo "No homepage in $FORMULA." >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || fail "Release from main."
[[ -z "$(git status --porcelain)" ]] || fail "The working tree has changes."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists." >&2
    exit 1
fi

echo "Releasing $VERSION ($MESSAGE)"
run plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
run plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
run git commit -m "$MESSAGE" -- "$PLIST"
run git tag "$TAG"
run git push origin main "$TAG"

if $DRY_RUN; then
    echo "+ sha256 of $TARBALL"
    echo "+ point $FORMULA at $TAG with that sha256"
else
    # GitHub can take a moment to serve a new tag's tarball.
    SHA=""
    for attempt in 1 2 3 4 5; do
        SHA="$(curl -fsSL "$TARBALL" | shasum -a 256 | cut -d' ' -f1)" && break
        SHA=""
        sleep 3
    done
    [[ -n "$SHA" ]] || { echo "Couldn't download $TARBALL." >&2; exit 1; }
    sed -i '' -e "s|^  url \".*\"$|  url \"$TARBALL\"|" -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" "$FORMULA"
    if ! grep -q "$TAG.tar.gz" "$FORMULA" || ! grep -q "$SHA" "$FORMULA"; then
        echo "Couldn't update $FORMULA." >&2
        exit 1
    fi
fi
run git commit -m "Set formula checksum for $TAG" -- "$FORMULA"
run git push origin main
echo "Released $TAG."
