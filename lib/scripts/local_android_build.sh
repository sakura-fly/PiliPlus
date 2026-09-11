#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— 本地 Android 打包脚本
#
# 适用：Flutter 项目本地构建 APK / AAB，自动生成版本信息和 dart-define，
#       构建完成后把产物复制到 dist/android 并重命名。
#
# 常用示例：
#   ./lib/scripts/local_android_build.sh                         # release + arm64-v8a
#   ./lib/scripts/local_android_build.sh --abi all               # release 通用 APK（全部 ABI）
#   ./lib/scripts/local_android_build.sh --type debug            # debug APK
#   ./lib/scripts/local_android_build.sh --format aab            # release AAB
#   ./lib/scripts/local_android_build.sh --dev --clean           # 开发包（applicationIdSuffix=.dev）
#
# 发布签名：把 keystore 和 android/key.properties 配好即可，Gradle 会自动使用；
#           如果没有 key.properties，release 会退回 debug 签名，脚本会给出警告。
#
# 依赖：flutter（或 fvm）、JDK 17、Android SDK。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"

# ----------------------------- 默认参数 --------------------------------------
BUILD_TYPE="release"
FORMAT="apk"
ABI="arm64-v8a"
OUTPUT_DIR="${PROJECT_ROOT}/dist/android"
FLUTTER_BIN=""
FLAVOR=""
CN_MIRROR=0
CLEAN=0
NO_PUB=0
NO_FVM=0
DEV=0
SPLIT=0
DRY_RUN=0
DEFINES_MODE="auto"          # auto | none | file
DART_DEFINES_FILE=""
VERSION_NAME=""
VERSION_CODE=""
EXTRA_ARGS=()

# ----------------------------- 输出工具 --------------------------------------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
PiliPlus 本地 Android 打包脚本

用法:
  ./lib/scripts/local_android_build.sh [选项] [-- <额外的 flutter build 参数>]

选项:
  -t, --type <release|debug|profile>  构建类型，默认 release
  -f, --format <apk|aab>              产物格式，默认 apk
  -a, --abi <all|arm64-v8a|armeabi-v7a|x86_64>
                                      目标 ABI，默认 arm64-v8a；
                                      all 表示构建通用包或全部 ABI
      --split                          按 ABI 拆包（仅 apk 有效）
      --dev                            构建 dev 变体（applicationIdSuffix=.dev）
      --clean                          构建前执行 flutter clean
      --no-pub                         不执行 flutter pub get
      --no-fvm                         跳过 fvm，直接使用 PATH 中的 flutter
      --cn-mirror                      临时使用腾讯 Gradle + 阿里云 Maven 镜像，构建后自动恢复
  -o, --output <目录>                  产物输出目录，默认 dist/android
  -F, --flavor <名称>                  Android product flavor
      --flutter <路径>                 指定 flutter 可执行文件
      --dart-define-from-file <文件>   使用指定的 dart-define JSON 文件
      --no-dart-defines                不生成/不使用 dart-define 文件
      --version-name <名称>            覆盖 versionName
      --version-code <数字>            覆盖 versionCode
      --dry-run                        只打印将要执行的命令
  -h, --help                           显示帮助

示例:
  ./lib/scripts/local_android_build.sh
  ./lib/scripts/local_android_build.sh --abi all
  ./lib/scripts/local_android_build.sh --type debug --clean
  ./lib/scripts/local_android_build.sh --format aab --abi all
  ./lib/scripts/local_android_build.sh -- --verbose
USAGE
}

need_value() {
  [ "$#" -ge 2 ] || die "选项 $1 需要一个参数"
}

# ----------------------------- 参数解析 --------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t|--type)
      need_value "$@"; BUILD_TYPE="$2"; shift 2 ;;
    --type=*) BUILD_TYPE="${1#*=}"; shift ;;
    -f|--format)
      need_value "$@"; FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    -a|--abi)
      need_value "$@"; ABI="$2"; shift 2 ;;
    --abi=*) ABI="${1#*=}"; shift ;;
    -o|--output)
      need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --output=*) OUTPUT_DIR="${1#*=}"; shift ;;
    -F|--flavor)
      need_value "$@"; FLAVOR="$2"; shift 2 ;;
    --flavor=*) FLAVOR="${1#*=}"; shift ;;
    --flutter)
      need_value "$@"; FLUTTER_BIN="$2"; shift 2 ;;
    --flutter=*) FLUTTER_BIN="${1#*=}"; shift ;;
    --dart-define-from-file)
      need_value "$@"; DART_DEFINES_FILE="$2"; DEFINES_MODE="file"; shift 2 ;;
    --dart-define-from-file=*)
      DART_DEFINES_FILE="${1#*=}"; DEFINES_MODE="file"; shift ;;
    --no-dart-defines)
      DEFINES_MODE="none"; shift ;;
    --version-name)
      need_value "$@"; VERSION_NAME="$2"; shift 2 ;;
    --version-name=*) VERSION_NAME="${1#*=}"; shift ;;
    --version-code)
      need_value "$@"; VERSION_CODE="$2"; shift 2 ;;
    --version-code=*) VERSION_CODE="${1#*=}"; shift ;;
    --clean) CLEAN=1; shift ;;
    --no-pub) NO_PUB=1; shift ;;
    --no-fvm) NO_FVM=1; shift ;;
    --cn-mirror) CN_MIRROR=1; shift ;;
    --dev) DEV=1; shift ;;
    --split) SPLIT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    -*) die "未知选项：$1（使用 --help 查看帮助）" ;;
    *) die "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

# ----------------------------- 参数校验 --------------------------------------
case "$BUILD_TYPE" in
  release|debug|profile) ;;
  *) die "--type 只能是 release、debug 或 profile，当前：$BUILD_TYPE" ;;
esac
case "$FORMAT" in
  apk|aab) ;;
  *) die "--format 只能是 apk 或 aab，当前：$FORMAT" ;;
esac
case "$ABI" in
  all|arm64-v8a|armeabi-v7a|x86_64) ;;
  *) die "--abi 只能是 all、arm64-v8a、armeabi-v7a 或 x86_64，当前：$ABI" ;;
esac

if [ "$FORMAT" = "aab" ] && [ "$SPLIT" -eq 1 ]; then
  warn "AAB 不支持 --split，已忽略该选项"
  SPLIT=0
fi

# 把相对输出目录固定到用户执行脚本时的目录，避免 cd 到仓库根目录后语义变化
case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}" ;;
esac

# 相对路径的 dart-define 文件固定到执行脚本时的目录
if [ -n "$DART_DEFINES_FILE" ] && [ "${DART_DEFINES_FILE#/}" = "$DART_DEFINES_FILE" ]; then
  DART_DEFINES_FILE="$(pwd)/${DART_DEFINES_FILE}"
fi

abi_to_platform() {
  case "$1" in
    arm64-v8a)   printf '%s' "android-arm64" ;;
    armeabi-v7a) printf '%s' "android-arm" ;;
    x86_64)      printf '%s' "android-x64" ;;
    *)           die "不支持的 ABI：$1" ;;
  esac
}

# ----------------------------- 选择 Flutter ----------------------------------
select_flutter() {
  if [ -n "$FLUTTER_BIN" ]; then
    [ -x "$FLUTTER_BIN" ] || die "--flutter 指定的文件不可执行：$FLUTTER_BIN"
    FLUTTER_CMD=("$FLUTTER_BIN")
    return
  fi

  if [ "$NO_FVM" -eq 0 ]; then
    if [ -x "${PROJECT_ROOT}/.fvm/flutter_sdk/bin/flutter" ]; then
      FLUTTER_CMD=("${PROJECT_ROOT}/.fvm/flutter_sdk/bin/flutter")
      return
    fi

    if command -v fvm >/dev/null 2>&1; then
      FLUTTER_CMD=(fvm flutter)
      return
    fi
  fi

  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_CMD=(flutter)
    return
  fi

  die "未找到 flutter/fvm。请安装 Flutter 或 FVM，或用 --flutter <路径> 指定。"
}

# ----------------------------- 版本信息 --------------------------------------
read_pubspec_version() {
  local line rest
  line="$(grep -E '^[[:space:]]*version:[[:space:]]*' "${PROJECT_ROOT}/pubspec.yaml" | head -n 1 || true)"
  [ -n "$line" ] || die "无法从 pubspec.yaml 读取 version"
  rest="${line#*:}"
  rest="$(printf '%s' "$rest" | tr -d '[:space:]')"
  rest="${rest%%#*}"                       # 去掉行尾注释
  rest="${rest%\}}"

  VERSION_NAME_FROM_PUBSPEC="${rest%%+*}"
  if [ "$rest" != "${rest%%+*}" ]; then
    VERSION_CODE_FROM_PUBSPEC="${rest##*+}"
  else
    VERSION_CODE_FROM_PUBSPEC="1"
  fi

  [ -n "$VERSION_NAME_FROM_PUBSPEC" ] || die "pubspec.yaml 中的 versionName 为空"
  case "$VERSION_CODE_FROM_PUBSPEC" in
    ''|*[!0-9]*) die "pubspec.yaml 中的 versionCode 不是数字：$VERSION_CODE_FROM_PUBSPEC" ;;
  esac
}

read_pubspec_version

# versionName 默认取 pubspec，versionCode 默认取 pubspec；如果 git 可用则取 commit 数，
# 与 CI 发布产物的 versionCode 规则保持一致。
if [ -z "$VERSION_NAME" ]; then
  VERSION_NAME="$VERSION_NAME_FROM_PUBSPEC"
fi

if [ -z "$VERSION_CODE" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION_CODE="$(git -C "$PROJECT_ROOT" rev-list --count HEAD)"
  else
    warn "无法使用 git 计算 versionCode，退回 pubspec.yaml 的 +$VERSION_CODE_FROM_PUBSPEC"
    VERSION_CODE="$VERSION_CODE_FROM_PUBSPEC"
  fi
fi
case "$VERSION_CODE" in
  ''|*[!0-9]*) die "versionCode 不是数字：$VERSION_CODE" ;;
esac

COMMIT_HASH="local"
if command -v git >/dev/null 2>&1; then
  COMMIT_HASH="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf 'local')"
fi

# ----------------------------- dart-define -----------------------------------
prepare_dart_defines() {
  case "$DEFINES_MODE" in
    none)
      DART_DEFINES_FILE=""
      return
      ;;
    file)
      [ -n "$DART_DEFINES_FILE" ] || die "--dart-define-from-file 缺少文件路径"
      [ -f "$DART_DEFINES_FILE" ] || die "dart-define 文件不存在：$DART_DEFINES_FILE"
      return
      ;;
    auto)
      local dir="${PROJECT_ROOT}/build"
      mkdir -p "$dir"
      DART_DEFINES_FILE="${dir}/local_dart_defines.json"
      local now
      now="$(date +%s)"
      # 所有值写成字符串，兼容 flutter --dart-define-from-file 的 JSON 格式。
      cat > "$DART_DEFINES_FILE" <<JSON
{"pili.name":"${VERSION_NAME}","pili.code":"${VERSION_CODE}","pili.hash":"${COMMIT_HASH}","pili.time":"${now}"}
JSON
      log "已生成本地 dart-define：${DART_DEFINES_FILE}"
      ;;
    *) die "未知 DEFINES_MODE：$DEFINES_MODE" ;;
  esac
}

# ----------------------------- 环境检查 --------------------------------------
check_environment() {
  if [ "$BUILD_TYPE" = "release" ] && [ ! -f "${PROJECT_ROOT}/android/key.properties" ]; then
    warn "未找到 android/key.properties，release 包将使用 debug 签名，仅供本地测试，请勿用于发布。"
  fi

  if ! command -v java >/dev/null 2>&1; then
    warn "未检测到 java 命令，Android 构建通常需要 JDK 17；如果你的 JDK 在 Android Studio 内，可用 --flutter 指定 Flutter 并确保 JAVA_HOME 正确。"
  fi

  local sdk_dir=""
  if [ -f "${PROJECT_ROOT}/android/local.properties" ]; then
    sdk_dir="$(grep -E '^[[:space:]]*sdk\.dir=' "${PROJECT_ROOT}/android/local.properties" | head -n 1 | cut -d= -f2- || true)"
  fi

  if [ -z "$sdk_dir" ] && [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    warn "未在 android/local.properties 或环境变量中找到 Android SDK；如果构建失败，请先配置 sdk.dir / ANDROID_HOME。"
  fi
}

# ----------------------------- 国内 Gradle 镜像 -------------------------------
# 说明：只临时修改 android/ 下的三个文件，构建结束（正常/异常/Ctrl-C）后自动恢复，
#       不会在 git 工作区留下改动。
GRADLE_BACKUP_DIR=""

restore_gradle_mirrors() {
  [ -n "${GRADLE_BACKUP_DIR:-}" ] || return 0
  local file name
  for file in \
    android/settings.gradle.kts \
    android/build.gradle.kts \
    android/gradle/wrapper/gradle-wrapper.properties
  do
    name="$(basename "$file")"
    if [ -f "${GRADLE_BACKUP_DIR}/${name}" ]; then
      cp -f "${GRADLE_BACKUP_DIR}/${name}" "$file"
    fi
  done
  rm -rf "$GRADLE_BACKUP_DIR"
  GRADLE_BACKUP_DIR=""
}

inject_aliyun_mirrors() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q 'maven.aliyun.com' "$file" && return 0
  sed -i.bak -E \
    -e 's|^([[:space:]]*)google\(\)$|\1maven { url = uri("https://maven.aliyun.com/repository/google") }\n\1google()|' \
    -e 's|^([[:space:]]*)mavenCentral\(\)$|\1maven { url = uri("https://maven.aliyun.com/repository/central") }\n\1mavenCentral()|' \
    -e 's|^([[:space:]]*)gradlePluginPortal\(\)$|\1maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }\n\1gradlePluginPortal()|' \
    "$file"
  rm -f "${file}.bak"
}

setup_gradle_mirrors() {
  [ "$CN_MIRROR" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 跳过 --cn-mirror 对 Gradle 配置文件的临时修改"
    return 0
  fi

  local file wrapper
  GRADLE_BACKUP_DIR="$(mktemp -d)"
  for file in \
    android/settings.gradle.kts \
    android/build.gradle.kts \
    android/gradle/wrapper/gradle-wrapper.properties
  do
    [ -f "$file" ] || die "启用 --cn-mirror 失败，文件不存在：$file"
    cp -f "$file" "${GRADLE_BACKUP_DIR}/$(basename "$file")"
  done

  trap restore_gradle_mirrors EXIT INT TERM

  inject_aliyun_mirrors android/settings.gradle.kts
  inject_aliyun_mirrors android/build.gradle.kts

  wrapper="android/gradle/wrapper/gradle-wrapper.properties"
  if ! grep -q 'mirrors.cloud.tencent.com/gradle' "$wrapper"; then
    sed -i.bak 's|services.gradle.org/distributions|mirrors.cloud.tencent.com/gradle|' "$wrapper"
    rm -f "${wrapper}.bak"
  fi
  log "已临时启用国内 Gradle/Maven 镜像，构建结束后自动恢复源文件"
}

# ----------------------------- 执行命令 --------------------------------------
run_cmd() {
  printf '\033[1;36m$\033[0m '
  printf '%q ' "$@"
  printf '\n'
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

# ----------------------------- 主流程 ----------------------------------------
main() {
  [ -f "${PROJECT_ROOT}/pubspec.yaml" ] || die "未找到 ${PROJECT_ROOT}/pubspec.yaml，脚本可能不在项目内"
  select_flutter
  log "使用 Flutter 命令：${FLUTTER_CMD[*]}"
  check_environment

  cd "$PROJECT_ROOT"

  if [ "$CLEAN" -eq 1 ]; then
    log "清理旧构建"
    run_cmd "${FLUTTER_CMD[@]}" clean
  fi

  # 注意：必须在 flutter clean 之后生成；否则 clean 会把自动生成的 build/local_dart_defines.json 删掉
  prepare_dart_defines

  if [ "$NO_PUB" -eq 0 ]; then
    log "拉取依赖"
    run_cmd "${FLUTTER_CMD[@]}" pub get
  fi

  setup_gradle_mirrors

  local build_args=("build")
  if [ "$FORMAT" = "apk" ]; then
    build_args+=("apk")
  else
    build_args+=("appbundle")
  fi

  build_args+=("--${BUILD_TYPE}")
  build_args+=("--build-name" "$VERSION_NAME")
  build_args+=("--build-number" "$VERSION_CODE")

  if [ -n "$FLAVOR" ]; then
    build_args+=("--flavor" "$FLAVOR")
  fi

  if [ "$DEV" -eq 1 ]; then
    build_args+=("--android-project-arg" "dev=1")
  fi

  if [ -n "$DART_DEFINES_FILE" ]; then
    build_args+=("--dart-define-from-file" "$DART_DEFINES_FILE")
  fi

  # 依赖获取由脚本控制：要么刚刚显式执行 pub get，要么用户指定 --no-pub。
  # 因此让 flutter build 不要再自行执行 pub get。
  build_args+=("--no-pub")

  if [ "$FORMAT" = "apk" ]; then
    if [ "$SPLIT" -eq 1 ]; then
      build_args+=("--split-per-abi")
    fi
    if [ "$ABI" != "all" ]; then
      build_args+=("--target-platform" "$(abi_to_platform "$ABI")")
    fi
  else
    # appbundle 默认包含全部 ABI；指定单个 ABI 时传给 Gradle
    if [ "$ABI" != "all" ]; then
      build_args+=("--target-platform" "$(abi_to_platform "$ABI")")
    fi
  fi

  if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    build_args+=("${EXTRA_ARGS[@]}")
  fi

  log "开始构建：type=${BUILD_TYPE}, format=${FORMAT}, abi=${ABI}, dev=${DEV}"
  run_cmd "${FLUTTER_CMD[@]}" "${build_args[@]}"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run 完成，未执行实际构建"
    return
  fi

  collect_and_copy_outputs
  log "构建完成，产物目录：${OUTPUT_DIR}"
  ls -lh "${OUTPUT_DIR}"
}

# ----------------------------- 产物收集 --------------------------------------
collect_and_copy_outputs() {
  local src_dir ext src base abi dest dev_suffix
  ext="$FORMAT"
  dev_suffix=""
  [ "$DEV" -eq 1 ] && dev_suffix="_dev"

  if [ "$FORMAT" = "apk" ]; then
    src_dir="${PROJECT_ROOT}/build/app/outputs/flutter-apk"
  else
    src_dir="${PROJECT_ROOT}/build/app/outputs/bundle/${BUILD_TYPE}"
  fi

  mkdir -p "$OUTPUT_DIR"

  local -a candidates=()
  shopt -s nullglob
  if [ "$FORMAT" = "apk" ]; then
    candidates=(
      "${src_dir}"/app-*-"${BUILD_TYPE}".apk
      "${src_dir}"/app-"${BUILD_TYPE}".apk
    )
  else
    candidates=(
      "${src_dir}"/app-*-"${BUILD_TYPE}".aab
      "${src_dir}"/app-"${BUILD_TYPE}".aab
    )
  fi
  shopt -u nullglob

  [ "${#candidates[@]}" -gt 0 ] || die "没有找到构建产物：${src_dir}/app-*-${BUILD_TYPE}.${ext}"

  local copied=0 name_abi
  for src in "${candidates[@]}"; do
    # 构建被中断时，Gradle/Flutter 可能已删掉部分产物；跳过即可，避免 cp 报 stat 失败。
    [ -f "$src" ] || continue
    base="$(basename "$src")"

    # 从 app-<abi>-release.apk 解析 ABI；AAB 或未 split 的 APK 没有 ABI 段。
    name_abi=""
    case "$base" in
      *-arm64-v8a-*)   name_abi="arm64-v8a" ;;
      *-armeabi-v7a-*) name_abi="armeabi-v7a" ;;
      *-x86_64-*)      name_abi="x86_64" ;;
    esac

    if [ -n "$name_abi" ]; then
      # 只有 --split 时才会产生带 ABI 的 APK；否则是上次构建残留，跳过。
      [ "$SPLIT" -eq 1 ] || continue
      if [ "$ABI" != "all" ] && [ "$name_abi" != "$ABI" ]; then
        continue
      fi
      abi="$name_abi"
    else
      # 不带 ABI 段的是通用 APK / AAB；--split 时忽略这类残留文件。
      [ "$SPLIT" -eq 0 ] || continue
      if [ "$ABI" = "all" ]; then
        abi="universal"
      else
        abi="$ABI"
      fi
    fi

    dest="${OUTPUT_DIR}/PiliPlus_android_${VERSION_NAME}+${VERSION_CODE}_${abi}_${BUILD_TYPE}${dev_suffix}.${ext}"
    cp -f "$src" "$dest"
    log "已生成：${dest}"
    copied=$((copied + 1))
  done

  [ "$copied" -gt 0 ] || die "没有找到与当前参数匹配的构建产物（format=${FORMAT}, abi=${ABI}, split=${SPLIT}）"
}

main
