#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— Gitee Go Android 打包脚本
# 由 .workflow/master-pipeline.yml 的 build@gcc 任务调用。
# 签名密钥由 Gitee 全局参数 KEYGEN_SEED 的前 32 位派生（同一种子=同一签名）。
# 依赖：build@gcc 执行器（Ubuntu 20.04）+ 网络
# =============================================================================
set -e

# 工作目录自检（应处于仓库根目录）
if [ ! -f pubspec.yaml ]; then
  echo "错误：当前目录不是 PiliPlus 仓库根目录（$PWD）" >&2
  exit 1
fi

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO=sudo

echo "==> 1/7 安装基础依赖"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
# 最小化容器常缺 man 目录，会导致 openjdk 的 update-alternatives 安装失败
$SUDO mkdir -p /usr/share/man/man1 /usr/share/man/man5 /usr/share/man/man6 /usr/share/man/man7 /usr/share/man/man8
$SUDO apt-get install -y -qq curl wget unzip zip xz-utils git gnupg openjdk-17-jdk-headless

echo "==> 2/7 安装 PowerShell（项目 patch 脚本需要）"
if ! command -v pwsh >/dev/null 2>&1; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | $SUDO gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
  CODENAME=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${CODENAME}/prod ${CODENAME} main" | $SUDO tee /etc/apt/sources.list.d/microsoft.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq powershell || {
    echo "MS 仓库安装失败，改用官方压缩包 ..."
    curl -fsSL -o /tmp/pwsh.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
    $SUDO mkdir -p /opt/microsoft/powershell/7
    $SUDO tar zxf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7
    $SUDO ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
  }
fi
command -v pwsh

echo "==> 3/7 准备 Flutter 与 Android SDK"
export FLUTTER_ROOT="$HOME/flutter"
if [ ! -d "$FLUTTER_ROOT" ]; then
  # 版本与 pubspec.yaml 的 flutter 字段保持一致
  git clone -q --depth 1 -b 3.47.2 https://github.com/flutter/flutter.git "$FLUTTER_ROOT"
fi
export PATH="$FLUTTER_ROOT/bin:$PATH"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [ ! -d "$ANDROID_HOME/cmdline-tools" ]; then
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  curl -fsSL -o /tmp/cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q /tmp/cmdtools.zip -d "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platform-tools" >/dev/null

echo "==> 4/7 由 KEYGEN_SEED 生成签名密钥"
SEED=$(printf '%s' "$KEYGEN_SEED" | tr -d '\n\r' | head -c 32)
if [ -z "$SEED" ]; then
  echo "错误：未配置全局参数 KEYGEN_SEED（仓库 -> 流水线 -> 全局参数）" >&2
  exit 1
fi
HASH=$(printf '%s' "$SEED" | sha256sum | cut -d' ' -f1)
STORE_PASS=$(printf '%s' "$HASH" | cut -c1-16)
KEY_PASS=$(printf '%s' "$HASH" | cut -c17-32)
ALIAS=piliplus
if [ ! -f android/app/key.jks ]; then
  keytool -genkeypair -keystore android/app/key.jks -storetype JKS \
    -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 36500 \
    -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
    -dname "CN=PiliPlus, OU=PiliPlus, O=PiliPlus, C=CN" -noprompt
  echo "已生成 android/app/key.jks（KEYGEN_SEED 派生，请勿再修改该种子）"
fi
printf 'storeFile=key.jks\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
  "$STORE_PASS" "$ALIAS" "$KEY_PASS" > android/key.properties

echo "==> 5/7 生成版本信息"
VERSION_NAME=$(sed -nE 's/^version:[[:space:]]*([0-9.]+).*/\1/p' pubspec.yaml | head -1)
VERSION_CODE=$(git rev-list --count HEAD)
COMMIT_HASH=$(git rev-parse HEAD)
SHORT_HASH=$(printf '%s' "$COMMIT_HASH" | cut -c1-9)
ANDROID_VERSION="$VERSION_NAME-$SHORT_HASH"
printf '{"pili.name":"%s","pili.code":"%s","pili.hash":"%s","pili.time":"%s"}\n' \
  "$ANDROID_VERSION" "$VERSION_CODE" "$COMMIT_HASH" "$(date +%s)" > pili_release.json
sed -i -E "s/^version: .*/version: $ANDROID_VERSION+$VERSION_CODE/" pubspec.yaml
echo "version: $ANDROID_VERSION+$VERSION_CODE"

echo "==> 6/7 应用项目补丁（失败不中断）"
export GITHUB_WORKSPACE="$PWD"
pwsh -File lib/scripts/patch.ps1 android || true

echo "==> 7/7 构建并重命名 APK"
flutter build apk --release --split-per-abi --dart-define-from-file=pili_release.json --pub

mkdir -p apk
for file in build/app/outputs/flutter-apk/app-*-release.apk; do
  abi=$(echo "$file" | sed -E 's|.*app-(.*)-release\.apk|\1|')
  mv "$file" "apk/PiliPlus_android_${ANDROID_VERSION}_${abi}.apk"
done
ls -lh apk/PiliPlus_android_*.apk
echo "构建完成"
