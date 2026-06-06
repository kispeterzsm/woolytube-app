#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0"
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

configure_java_21() {
  local java_home="${JAVA_21_HOME:-/usr/lib/jvm/java-21-openjdk}"

  if [[ ! -x "$java_home/bin/java" ]]; then
    echo "Missing Java 21 at $java_home. Set JAVA_21_HOME to the JDK 21 path." >&2
    exit 69
  fi

  export JAVA_HOME="$java_home"
  export PATH="$JAVA_HOME/bin:$PATH"
}

FLUTTER_BIN="$(resolve_command FLUTTER_BIN flutter /home/wooly/flutter/bin/flutter)"
ASSET_DIR="build/releases"
ASSET_NAME="woolytube-local.apk"
ASSET_PATH="$ASSET_DIR/$ASSET_NAME"

configure_java_21

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release

mkdir -p "$ASSET_DIR"
cp build/app/outputs/flutter-apk/app-release.apk "$ASSET_PATH"

echo "Built $ASSET_PATH"
