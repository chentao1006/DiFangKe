#!/usr/bin/env bash

# Build, install, and launch the direct debug variant on one connected Android
# device. Existing application data is deliberately preserved.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
PACKAGE_NAME="com.ct106.difangke"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/direct/debug/app-direct-debug.apk"

command -v adb >/dev/null 2>&1 || {
  echo "错误：未找到 adb。请安装 Android SDK Platform-Tools 并加入 PATH。" >&2
  exit 1
}

DEVICES=()
while IFS= read -r serial; do
  [[ -n "$serial" ]] && DEVICES+=("$serial")
done < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  SERIAL="$ANDROID_SERIAL"
  if ! printf '%s\n' "${DEVICES[@]}" | grep -Fxq "$SERIAL"; then
    echo "错误：ANDROID_SERIAL=$SERIAL 当前未处于 device 状态。" >&2
    adb devices -l >&2
    exit 1
  fi
elif [[ ${#DEVICES[@]} -eq 1 ]]; then
  SERIAL="${DEVICES[0]}"
elif [[ ${#DEVICES[@]} -eq 0 ]]; then
  echo "错误：没有检测到已授权的 Android 真机。请连接设备并开启 USB 调试。" >&2
  adb devices -l >&2
  exit 1
else
  echo "错误：检测到多个设备。请指定目标，例如：ANDROID_SERIAL=<serial> ./test_android.sh" >&2
  adb devices -l >&2
  exit 1
fi

echo "==> 构建 directDebug"
(
  cd "$ANDROID_DIR"
  ./gradlew :app:assembleDirectDebug
)

[[ -f "$APK_PATH" ]] || {
  echo "错误：未找到构建产物：$APK_PATH" >&2
  exit 1
}

echo "==> 安装到 ${SERIAL}（保留应用数据）"
adb -s "${SERIAL}" install -r -d "$APK_PATH"

echo "==> 启动地方客"
adb -s "${SERIAL}" shell am force-stop "$PACKAGE_NAME"
adb -s "${SERIAL}" shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null

echo "完成：地方客已在 ${SERIAL} 上启动。"
