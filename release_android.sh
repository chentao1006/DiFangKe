#!/bin/bash

# 获取脚本所在目录（根目录）
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

GRADLE_FILE="$ROOT_DIR/android/app/build.gradle.kts"
APK_SOURCE="$ROOT_DIR/android/app/release/app-release.apk"
DEPLOY_DIR="$ROOT_DIR/download"
APK_DEST="$DEPLOY_DIR/difangke.apk"
JSON_DEST="$DEPLOY_DIR/update_android.json"

echo "🏗️  开始打包 APK (assembleRelease)..."

# 1. 运行打包命令 (确保 gradlew 有执行权限)
cd "$ROOT_DIR/android"
chmod +x gradlew
./gradlew assembleRelease
if [ $? -ne 0 ]; then
    echo "❌ 错误: 打包失败，请检查上面的编译报错。"
    exit 1
fi
cd "$ROOT_DIR"

echo "🚀 开始自动化发布流程..."

# 2. 检查输出文件
if [ ! -f "$APK_SOURCE" ]; then
    # 尝试另一个常见的输出路径
    ALT_APK_SOURCE="$ROOT_DIR/android/app/build/outputs/apk/release/app-release.apk"
    if [ -f "$ALT_APK_SOURCE" ]; then
        APK_SOURCE=$ALT_APK_SOURCE
    else
        echo "❌ 错误: 找不到生成的 APK 文件。"
        exit 1
    fi
fi

# 3. 提取版本信息
VERSION_CODE=$(grep 'versionCode[[:space:]]*=' "$GRADLE_FILE" | awk -F'=' '{print $2}' | tr -d '[:space:]')
VERSION_NAME=$(grep 'versionName[[:space:]]*=' "$GRADLE_FILE" | awk -F'"' '{print $2}')

[ -z "$VERSION_CODE" ] && VERSION_CODE="1"
[ -z "$VERSION_NAME" ] && VERSION_NAME="1.0.0"

echo "📦 检测到版本: $VERSION_NAME (Build $VERSION_CODE)"

# 4. 准备目录与复制
mkdir -p "$DEPLOY_DIR"
cp "$APK_SOURCE" "$APK_DEST"
echo "✅ 已复制 APK 至: $APK_DEST"

# 5. 更新 JSON
cat <<EOF > "$JSON_DEST"
{
  "versionCode": $VERSION_CODE,
  "versionName": "$VERSION_NAME",
  "downloadUrl": "https://difangke.cn/download/difangke.apk",
  "releaseNotes": "1. 自动打包发布版本 $VERSION_NAME\n2. 修复已知问题并提升稳定性"
}
EOF

echo "✅ 已更新配置文件: $JSON_DEST"
echo ""
echo "🎉 发布就绪！你可以上传 download 目录了。"
