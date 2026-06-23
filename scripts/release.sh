#!/bin/bash
set -euo pipefail

# Usage: scripts/release.sh <version>       e.g. scripts/release.sh 0.1.3
#
# Full release pipeline:
#   1. Preflight (on main, tree clean, tag free, in sync with origin)
#   2. Bump CFBundleShortVersionString + auto-increment CFBundleVersion
#   3. Prompt for release notes in $EDITOR (prefilled with recent commits)
#   4. Run bundle.sh release --dist
#   5. Commit + push version bump
#   6. Tag + push tag
#   7. gh release create with the DMG and notes
#
# Bails out before anything public-visible if a preflight check fails.

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>  (e.g. 0.1.3)" >&2
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/PalmierPro/Resources/Info.plist"
DMG="$ROOT/.build/PalmierSlate.dmg"
cd "$ROOT"

echo "==> Preflight"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: must be on main (got: $BRANCH)" >&2
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "error: working tree has uncommitted changes:" >&2
  git status --short >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi

git fetch origin main --quiet
git fetch origin --tags --quiet
if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "error: local main differs from origin/main. Push or pull first." >&2
  exit 1
fi

echo "==> Generating release notes from commit log"
NOTES_CLEAN="$(mktemp -t palmier-release.XXXXXX).md"
trap 'rm -f "$NOTES_CLEAN"' EXIT
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
{
  echo "## What's new"
  echo ""
  if [ -n "$LAST_TAG" ]; then
    git log --pretty=format:"- %s" "$LAST_TAG..HEAD"
    echo ""
  else
    echo "First release."
  fi
} >"$NOTES_CLEAN"
echo "    (edit on GitHub later if you want to polish)"

echo "==> Bumping version"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
NEW_BUILD=$((CURRENT_BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "    $VERSION (build $NEW_BUILD)"

echo "==> Building signed + notarized DMG"
./scripts/bundle.sh release --dist

echo "==> Committing + pushing version bump"
git add "$PLIST"
git commit -m "Bump to $VERSION"
git push origin main

echo "==> Tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating GH release"
gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES_CLEAN"

echo ""
echo "==> Released $TAG"
echo "    https://github.com/nikolan123/palmier-slate/releases/tag/$TAG"
