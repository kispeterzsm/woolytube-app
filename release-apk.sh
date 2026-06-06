#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.5.6"
  exit 64
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use MAJOR.MINOR.PATCH format, for example 0.5.6" >&2
  exit 64
fi

for command in flutter gh git; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 69
  fi
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes before creating a release." >&2
  exit 65
fi

IFS=. read -r MAJOR MINOR PATCH <<<"$VERSION"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
if (( BUILD_NUMBER <= 0 )); then
  BUILD_NUMBER=1
fi

TAG="v$VERSION"
REPO="${GH_REPO:-kispeterzsm/woolytube-app}"
ASSET_DIR="build/releases"
ASSET_NAME="woolytube-$VERSION.apk"
ASSET_PATH="$ASSET_DIR/$ASSET_NAME"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists in $REPO" >&2
  exit 65
fi

flutter pub get
flutter build apk \
  --release \
  --build-name "$VERSION" \
  --build-number "$BUILD_NUMBER"

mkdir -p "$ASSET_DIR"
cp build/app/outputs/flutter-apk/app-release.apk "$ASSET_PATH"

gh release create "$TAG" "$ASSET_PATH" \
  --repo "$REPO" \
  --title "WoolyTube $VERSION" \
  --notes "WoolyTube $VERSION"

echo "Published $TAG to $REPO with $ASSET_NAME"
