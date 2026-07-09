#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0"
  exit 64
fi

resolve_adb() {
  if [[ -n "${ADB_BIN:-}" ]]; then
    if [[ -x "$ADB_BIN" ]]; then
      printf '%s\n' "$ADB_BIN"
      return
    fi
    echo "ADB_BIN is set but is not executable: $ADB_BIN" >&2
    exit 69
  fi

  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi

  for candidate in \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "Missing required command: adb. Set ADB_BIN or add adb to PATH." >&2
  exit 69
}

choose_device() {
  local adb_bin="$1"
  local -a devices

  mapfile -t devices < <("$adb_bin" devices -l | awk 'NR > 1 && $2 == "device" {print}')

  case "${#devices[@]}" in
    0)
      echo "No online authorized adb devices found." >&2
      echo >&2
      "$adb_bin" devices -l >&2
      exit 69
      ;;
    1)
      awk '{print $1}' <<<"${devices[0]}"
      ;;
    *)
      echo "Choose an adb device:"
      local index=1
      local device
      for device in "${devices[@]}"; do
        printf '  %d) %s\n' "$index" "$device"
        index=$((index + 1))
      done

      local choice
      while true; do
        read -r -p "Device number: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#devices[@]})); then
          awk '{print $1}' <<<"${devices[choice - 1]}"
          return
        fi
        echo "Enter a number from 1 to ${#devices[@]}."
      done
      ;;
  esac
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ADB_BIN="$(resolve_adb)"
DEVICE_SERIAL="$(choose_device "$ADB_BIN")"

cd "$SCRIPT_DIR"

APK_PATH="build/releases/woolytube-local.apk"

if [[ ! -f "$APK_PATH" ]]; then
  APK_PATH="$(find build -type f -name '*.apk' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 {print $2}')"
fi

if [[ -z "${APK_PATH:-}" || ! -f "$APK_PATH" ]]; then
  echo "No APK found. Run ./build-apk.sh first." >&2
  exit 70
fi

"$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APK_PATH"

echo "Installed $APK_PATH on $DEVICE_SERIAL"
