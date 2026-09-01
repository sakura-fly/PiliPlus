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
  # URL 用数字版本号，发行版字段用代号（如 22.04 + jammy）
  . /etc/os-release
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${VERSION_CODENAME} main" | $SUDO tee /etc/apt/sources.list.d/microsoft.list >/dev/null
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
# 增大 Git 缓冲区，降低大仓库克隆时 RPC failed / early EOF 的概率
git config --global http.postBuffer 524288000
# 放宽限速阈值，避免大仓库镜像克隆被误判为"过慢"而中止
git config --global http.lowSpeedLimit 100
git config --global http.lowSpeedTime 600

export FLUTTER_ROOT="$HOME/flutter"
if [ ! -d "$FLUTTER_ROOT" ]; then
  # 版本与 pubspec.yaml 的 flutter 字段保持一致
  # 优先 GitHub，失败自动切换 Gitee 镜像（国内 CI 访问 GitHub 经常断流）
  FLUTTER_VERSION=3.47.2
  FLUTTER_CLONE_OK=0
  for url in \
      "https://github.com/flutter/flutter.git" \
      "https://gitee.com/mirrors/Flutter.git"
  do
    echo "尝试克隆 Flutter SDK：${url}"
    if git clone -q --depth 1 -b "${FLUTTER_VERSION}" "$url" "$FLUTTER_ROOT"; then
      FLUTTER_CLONE_OK=1
      break
    fi
    echo "克隆失败，清理后尝试下一个镜像..."
    rm -rf "$FLUTTER_ROOT"
  done
  if [ "$FLUTTER_CLONE_OK" -ne 1 ]; then
    echo "错误：Flutter SDK 克隆失败（GitHub 与 Gitee 镜像均不可用）" >&2
    exit 1
  fi
fi
export PATH="$FLUTTER_ROOT/bin:$PATH"
# 国内 CI 使用 Flutter 镜像加速 pub 与引擎下载
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

# Gitee 执行器访问 GitHub 不稳定：pub get 的 git 依赖统一改走国内代理
git config --global url."https://ghfast.top/https://github.com/".insteadOf "https://github.com/"

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
# patch.ps1 硬编码查找 ~/.pub-cache/hosted/pub.dev，而镜像源缓存位于 pub.flutter-io.cn 下。
# 注意：此刻目录尚未生成（pub get 在 patch.ps1 内部执行），悬空链接会在目录创建后自动生效。
mkdir -p "$HOME/.pub-cache/hosted"
if [ ! -e "$HOME/.pub-cache/hosted/pub.dev" ]; then
  ln -s "$HOME/.pub-cache/hosted/pub.flutter-io.cn" "$HOME/.pub-cache/hosted/pub.dev"
  echo "已建立 pub 缓存符号链接: pub.dev -> pub.flutter-io.cn"
fi
export GITHUB_WORKSPACE="$PWD"
pwsh -File lib/scripts/patch.ps1 android || true

echo "==> 7/7 构建并重命名 APK"

# Gradle 发行版改走腾讯镜像（services.gradle.org 连接超时）
WRAPPER_PROP=android/gradle/wrapper/gradle-wrapper.properties
if [ -f "$WRAPPER_PROP" ]; then
  sed -i 's|services.gradle.org/distributions|mirrors.cloud.tencent.com/gradle|' "$WRAPPER_PROP"
  echo "Gradle 发行版镜像: $(grep -h distributionUrl "$WRAPPER_PROP" || true)"
fi

# 注意：不要用 init 脚本注入任何 Gradle 仓库——Gradle 9.5 的 PREFER_SETTINGS 模式
# 会报 "repository 'maven' was added by settings file" 并中断构建。
# 插件与依赖仓库直接用项目自带的 google()/mavenCentral()/gradlePluginPortal()
# （dl.google.com 已确认可达：Android cmdline-tools 下载成功）。
# 若后续依赖下载超时，再考虑把阿里云镜像直接写进 settings.gradle.kts / build.gradle.kts。

flutter build apk --release --split-per-abi --dart-define-from-file=pili_release.json --pub

mkdir -p apk
for file in build/app/outputs/flutter-apk/app-*-release.apk; do
  abi=$(echo "$file" | sed -E 's|.*app-(.*)-release\.apk|\1|')
  mv "$file" "apk/PiliPlus_android_${ANDROID_VERSION}_${abi}.apk"
done
ls -lh apk/PiliPlus_android_*.apk
echo "构建完成"
