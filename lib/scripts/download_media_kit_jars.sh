#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— 预下载 media_kit_libs_android_video 需要的 libmpv jar
#
# Gradle 里 media_kit_libs_android_video 使用 Java URL.openStream() 下载 GitHub
# Release 资源，没有断点续传/重试，国内网络容易下载出截断文件，导致：
#   SHA-256 verification failed for .../default-armeabi-v7a.jar
#
# 这个脚本用 curl 预下载并校验 SHA-256，校验通过后放到 Gradle 期望的位置，
# Gradle 后续会直接复用，不再自己下载。
#
# 使用：
#   bash lib/scripts/download_media_kit_jars.sh
#   bash lib/scripts/download_media_kit_jars.sh --force
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"

BASE_URL="https://github.com/My-Responsitories/libmpv-android-video-build/releases/download/20260906"
DEST_DIR="${PROJECT_ROOT}/build/media_kit_libs_android_video/20260906"
FORCE=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法:
  bash lib/scripts/download_media_kit_jars.sh [--force]

选项:
  --force   即使本地文件 SHA-256 正确也重新下载
  -h, --help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "未找到 curl"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "未找到 sha256sum / shasum"
  fi
}

download_one() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local dest="${DEST_DIR}/${name}"
  local tmp="${dest}.part"

  if [ "$FORCE" -eq 0 ] && [ -f "$dest" ]; then
    local actual
    actual="$(sha256_of "$dest")"
    if [ "$actual" = "$expected" ]; then
      log "已存在且 SHA-256 正确，跳过：${name}"
      return 0
    fi
    warn "SHA-256 不匹配，重新下载：${name}"
    rm -f "$dest"
  fi

  mkdir -p "$DEST_DIR"
  rm -f "$tmp"

  log "下载：${url}"
  # --noproxy '*' 是为了绕过可能配置错误的环境代理；GitHub Release 资源直连通常可用。
  # --http1.1 避免部分网络环境下 HTTP/2 framing 报错。
  if ! curl --noproxy '*' --http1.1 -fL \
      --retry 10 --retry-delay 3 --connect-timeout 20 --max-time 600 \
      -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "下载失败：${name}"
  fi

  local actual
  actual="$(sha256_of "$tmp")"
  if [ "$actual" != "$expected" ]; then
    rm -f "$tmp"
    die "SHA-256 校验失败：${name}，期望 ${expected}，实际 ${actual}"
  fi

  mv -f "$tmp" "$dest"
  log "完成：${dest}"
}

main() {
  [ -f "${PROJECT_ROOT}/pubspec.yaml" ] || die "当前目录不是 PiliPlus 仓库：${PROJECT_ROOT}"

  # 与 media_kit_libs_android_video/android/build.gradle 中的 filesToDownload 保持一致
  download_one \
    "default-arm64-v8a.jar" \
    "${BASE_URL}/default-arm64-v8a.jar" \
    "98df6410375cc7a4be7e6eff56f9ccd88fa52678973cc23bcf7e934ab8c8682d"

  download_one \
    "default-armeabi-v7a.jar" \
    "${BASE_URL}/default-armeabi-v7a.jar" \
    "75ba2199848cd6224817320ddfabb7d7ea48fb4cfb1721b0090043d5a8a38602"

  download_one \
    "default-x86_64.jar" \
    "${BASE_URL}/default-x86_64.jar" \
    "1caa6198de22808bd7f10fcff2923f5eb174cc42ef24569aeafb98c6597457a4"

  log "media_kit jar 已全部就绪：${DEST_DIR}"
}

main
