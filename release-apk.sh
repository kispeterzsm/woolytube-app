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

resolve_command() {
  local env_var="$1"
  local command_name="$2"
  local fallback_path="${3:-}"
  local configured_path="${!env_var:-}"

  if [[ -n "$configured_path" ]]; then
    if [[ -x "$configured_path" ]]; then
      printf '%s\n' "$configured_path"
      return
    fi
    echo "$env_var is set but is not executable: $configured_path" >&2
    exit 69
  fi

  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return
  fi

  if [[ -n "$fallback_path" && -x "$fallback_path" ]]; then
    printf '%s\n' "$fallback_path"
    return
  fi

  echo "Missing required command: $command_name" >&2
  exit 69
}

FLUTTER_BIN="$(resolve_command FLUTTER_BIN flutter /home/wooly/flutter/bin/flutter)"
GH_BIN="$(resolve_command GH_BIN gh)"
GIT_BIN="$(resolve_command GIT_BIN git)"

if [[ -z "${JAVA_HOME:-}" && -d /usr/lib/jvm/java-21-openjdk ]]; then
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
fi

if [[ -n "$("$GIT_BIN" status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes before creating a release." >&2
  exit 65
fi

CURRENT_BRANCH="$("$GIT_BIN" rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "Cannot create a release from a detached HEAD." >&2
  exit 65
fi

IFS=. read -r MAJOR MINOR PATCH <<<"$VERSION"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
if (( BUILD_NUMBER <= 0 )); then
  BUILD_NUMBER=1
fi
PUBSPEC_VERSION="$VERSION+$BUILD_NUMBER"

TAG="v$VERSION"
REPO="${GH_REPO:-kispeterzsm/woolytube-app}"
REMOTE="${RELEASE_REMOTE:-origin}"
ASSET_DIR="build/releases"
ASSET_NAME="woolytube-$VERSION.apk"
ASSET_PATH="$ASSET_DIR/$ASSET_NAME"

if "$GH_BIN" release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists in $REPO" >&2
  exit 65
fi

ORIGINAL_PUBSPEC_VERSION="$(sed -n 's/^version: //p' pubspec.yaml)"
if [[ -z "$ORIGINAL_PUBSPEC_VERSION" ]]; then
  echo "pubspec.yaml does not contain a version field." >&2
  exit 66
fi

VERSION_COMMITTED=false
restore_version_on_failure() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && "$VERSION_COMMITTED" == false ]]; then
    perl -0pi -e \
      "s/^version: .*\$/version: $ORIGINAL_PUBSPEC_VERSION/m" \
      pubspec.yaml
  fi
}
trap restore_version_on_failure EXIT

perl -0pi -e "s/^version: .*\$/version: $PUBSPEC_VERSION/m" pubspec.yaml

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk \
  --release \
  --build-name "$VERSION" \
  --build-number "$BUILD_NUMBER"

mkdir -p "$ASSET_DIR"
cp build/app/outputs/flutter-apk/app-release.apk "$ASSET_PATH"

if ! "$GIT_BIN" diff --quiet -- pubspec.yaml; then
  "$GIT_BIN" add pubspec.yaml
  "$GIT_BIN" commit -m "Release $VERSION"
  VERSION_COMMITTED=true
  "$GIT_BIN" push "$REMOTE" "$CURRENT_BRANCH"
fi

"$GH_BIN" release create "$TAG" "$ASSET_PATH" \
  --repo "$REPO" \
  --target "$CURRENT_BRANCH" \
  --title "WoolyTube $VERSION" \
  --notes "WoolyTube $VERSION"

echo "Published $TAG to $REPO with $ASSET_NAME"
