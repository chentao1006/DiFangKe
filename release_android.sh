#!/bin/bash

# 获取脚本所在目录（根目录）
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

GRADLE_FILE="$ROOT_DIR/android/app/build.gradle.kts"
APK_SOURCE="$ROOT_DIR/android/app/build/outputs/apk/release/app-release.apk"
DEPLOY_DIR="$ROOT_DIR/download"
APK_DEST="$DEPLOY_DIR/difangke.apk"
JSON_DEST="$DEPLOY_DIR/update_android.json"

# --- 自动版本更新 ---
VERSION_PROPS="$ROOT_DIR/android/version.properties"
CURRENT_VERSION_CODE=$(grep "^VERSION_CODE=" "$VERSION_PROPS" | cut -d'=' -f2 | tr -d '[:space:]')
CURRENT_VERSION_NAME=$(grep "^VERSION_NAME=" "$VERSION_PROPS" | cut -d'=' -f2 | tr -d '[:space:]')

echo "----------------------------------------"
echo "📦 当前项目版本: $CURRENT_VERSION_NAME (Build $CURRENT_VERSION_CODE)"
read -p "请输入新的版本号 [回车保持 $CURRENT_VERSION_NAME]: " NEW_VERSION_NAME
[ -z "$NEW_VERSION_NAME" ] && NEW_VERSION_NAME=$CURRENT_VERSION_NAME

# 自动递增 Version Code
NEW_VERSION_CODE=$((CURRENT_VERSION_CODE + 1))

echo "🔄 正在更新版本号到 $NEW_VERSION_NAME ($NEW_VERSION_CODE)..."
sed -i '' "s/^VERSION_CODE=.*/VERSION_CODE=$NEW_VERSION_CODE/" "$VERSION_PROPS"
sed -i '' "s/^VERSION_NAME=.*/VERSION_NAME=$NEW_VERSION_NAME/" "$VERSION_PROPS"
echo "----------------------------------------"
echo ""

echo "🏗️  开始打包 APK (assembleRelease)..."

# 1. 运行打包命令 (确保 gradlew 有执行权限)
cd "$ROOT_DIR/android"
chmod +x gradlew
./gradlew clean assembleRelease --no-configuration-cache
if [ $? -ne 0 ]; then
    echo "❌ 错误: 打包失败，请检查上面的编译报错。"
    exit 1
fi
cd "$ROOT_DIR"

echo "🚀 开始自动化发布流程..."

# 2. 检查输出文件
if [ ! -f "$APK_SOURCE" ]; then
    # 只允许已签名的正式版本
    APK_SOURCE="$ROOT_DIR/android/app/build/outputs/apk/release/app-release.apk"
    
    if [ ! -f "$APK_SOURCE" ]; then
        echo "❌ 错误: 找不到签名的 APK 文件 (app-release.apk)。"
        echo "💡 提示: 请确保 build.gradle.kts 中配置了正确的 signingConfigs 且密码正确。"
        exit 1
    fi
fi

# 3. 提取版本信息
get_version_prop() {
    grep "^${1}=" "$ROOT_DIR/android/version.properties" | cut -d'=' -f2 | tr -d '[:space:]'
}
get_local_prop() {
    grep "^${1}=" "$ROOT_DIR/android/local.properties" | cut -d'=' -f2 | tr -d '[:space:]'
}

VERSION_CODE=$(get_version_prop "VERSION_CODE")
VERSION_NAME=$(get_version_prop "VERSION_NAME")

[ -z "$VERSION_CODE" ] && VERSION_CODE="1"
[ -z "$VERSION_NAME" ] && VERSION_NAME="1.0.0"

echo "📦 检测到版本: $VERSION_NAME (Build $VERSION_CODE)"

# 4. 准备目录与复制
mkdir -p "$DEPLOY_DIR"

# 4.1 手动强制重新签署 (确保同时拥有 V1 和 V2 证书)
SDK_DIR=$(grep "^sdk.dir=" "$ROOT_DIR/android/local.properties" | cut -d'=' -f2)
APKSIGNER=$(find "$SDK_DIR/build-tools" -name "apksigner" | sort -r | head -n 1)
KS_PATH="$ROOT_DIR/android/difangke.jks"
KS_PASS=$(get_local_prop "STORE_PASSWORD")
KEY_ALIAS=$(get_local_prop "KEY_ALIAS")

if [ -x "$APKSIGNER" ] && [ -f "$KS_PATH" ]; then
    echo "🔏 正在进行手动二次签署 (强制开启 V1/V2)..."
    "$APKSIGNER" sign --ks "$KS_PATH" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KEY_ALIAS" --key-pass "pass:$KS_PASS" --v1-signing-enabled true --v2-signing-enabled true "$APK_SOURCE"
    if [ $? -eq 0 ]; then
        echo "✅ 手动签署完成！验证证书中..."
        "$APKSIGNER" verify -v "$APK_SOURCE" | grep "Verified using v"
    else
        echo "⚠️  警告: 手动签署失败，将使用原始编译文件。"
    fi
fi

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

# 5.1 更新 index.html 中的下载链接 (防止缓存)
INDEX_FILE="$ROOT_DIR/index.html"
if [ -f "$INDEX_FILE" ]; then
    echo "🌐 正在更新 index.html 中的下载链接版本号..."
    # 使用 VERSION_CODE 作为 query 参数，适配 macOS 的 sed
    sed -i '' "s|download/difangke.apk[^\"']*|download/difangke.apk?v=$VERSION_CODE|g" "$INDEX_FILE"
    echo "✅ index.html 已更新"
fi
echo ""
echo "🎉 发布就绪！你可以上传 download 目录了。"
echo ""

# 6. Git 提交与推送
echo "📝 正在提交代码至 Git..."
git add .
# 这里使用 || true 是为了防止因为没变动导致脚本报错退出
git commit -m "chore: release version $VERSION_NAME (Build $VERSION_CODE)" || true
git push
echo "🚀 代码已同步至远程仓库"
