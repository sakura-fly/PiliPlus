#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— 在 Linux/macOS 上应用 Android 打包所需补丁
#
# 作用等价于在 Windows 上执行：
#   pwsh -File lib/scripts/patch.ps1 android
#
# 但不需要安装 PowerShell，直接用 git apply：
#   1. 给当前 FVM/Flutter SDK 打 Android 相关补丁
#   2. 给当前 pub 缓存里的 material_ui 包打补丁
#
# 使用：
#   bash lib/scripts/apply_android_patches.sh
#   bash lib/scripts/apply_android_patches.sh --no-reset
#   bash lib/scripts/apply_android_patches.sh --dry-run
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"

FLUTTER_BIN=""
NO_RESET=0
DRY_RUN=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法:
  bash lib/scripts/apply_android_patches.sh [选项]

选项:
  --flutter <路径>   指定 flutter 可执行文件，默认自动查找
                     顺序：FLUTTER_ROOT 环境变量 -> .fvm/flutter_sdk -> PATH 中的 flutter
  --no-reset         不执行 git reset --hard，适用于你自己维护 Flutter SDK 改动
  --dry-run          只检查补丁能否应用，不实际写入
  -h, --help         显示帮助
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flutter)
      [ "$#" -ge 2 ] || die "--flutter 需要一个参数"
      FLUTTER_BIN="$2"; shift 2 ;;
    --flutter=*) FLUTTER_BIN="${1#*=}"; shift ;;
    --no-reset) NO_RESET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

find_flutter_root() {
  local candidate bin fvm_version fvm_root

  if [ -n "$FLUTTER_BIN" ]; then
    [ -x "$FLUTTER_BIN" ] || die "--flutter 指定的文件不可执行：$FLUTTER_BIN"
  else
    # 1) CI 环境通常显式设置 FLUTTER_ROOT
    if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "${FLUTTER_ROOT}/bin/flutter" ]; then
      FLUTTER_BIN="${FLUTTER_ROOT}/bin/flutter"
    fi

    # 2) 优先按 .fvmrc 解析 FVM SDK，兼容 .fvm/flutter_sdk 软链还未更新的情况
    if [ -z "$FLUTTER_BIN" ] && [ -f "${PROJECT_ROOT}/.fvmrc" ] && command -v python3 >/dev/null 2>&1; then
      fvm_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("flutter", ""))' "${PROJECT_ROOT}/.fvmrc" 2>/dev/null || true)"
      if [ -n "$fvm_version" ]; then
        for fvm_root in \
          "${FVM_HOME:-$HOME/fvm}/versions/${fvm_version}" \
          "$HOME/fvm/versions/${fvm_version}" \
          "$HOME/.fvm/versions/${fvm_version}" \
          "${PROJECT_ROOT}/.fvm/versions/${fvm_version}"; do
          if [ -x "${fvm_root}/bin/flutter" ]; then
            FLUTTER_BIN="${fvm_root}/bin/flutter"
            break
          fi
        done
      fi
    fi

    # 3) 仍找不到时，让 fvm 自己输出当前项目实际使用的 flutterRoot
    if [ -z "$FLUTTER_BIN" ] && command -v fvm >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      fvm_root="$(fvm flutter --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("flutterRoot", ""))' 2>/dev/null || true)"
      if [ -n "$fvm_root" ] && [ -x "${fvm_root}/bin/flutter" ]; then
        FLUTTER_BIN="${fvm_root}/bin/flutter"
      fi
    fi

    # 4) 传统 .fvm/flutter_sdk 软链接
    if [ -z "$FLUTTER_BIN" ] && [ -x "${PROJECT_ROOT}/.fvm/flutter_sdk/bin/flutter" ]; then
      FLUTTER_BIN="${PROJECT_ROOT}/.fvm/flutter_sdk/bin/flutter"
    fi

    # 5) PATH 中的 flutter
    if [ -z "$FLUTTER_BIN" ] && command -v flutter >/dev/null 2>&1; then
      FLUTTER_BIN="$(command -v flutter)"
    fi

    [ -n "$FLUTTER_BIN" ] || die "未找到 flutter，可用 --flutter <路径> 指定，或先执行 fvm use"
  fi

  [ -x "$FLUTTER_BIN" ] || die "flutter 不可执行：$FLUTTER_BIN"

  # 支持 bin/flutter 是符号链接的情况
  candidate="$FLUTTER_BIN"
  while [ -L "$candidate" ]; do
    bin="$(readlink "$candidate")"
    case "$bin" in
      /*) candidate="$bin" ;;
      *)  candidate="$(cd "$(dirname "$candidate")" && pwd)/$bin" ;;
    esac
  done

  candidate="$(cd "$(dirname "$candidate")/.." && pwd)"
  [ -f "$candidate/bin/flutter" ] || die "无法确定 Flutter SDK 根目录：$candidate"
  printf '%s' "$candidate"
}

apply_patch() {
  local dir="$1"
  local patch="$2"
  local label="$3"

  [ -f "$patch" ] || die "补丁不存在：$patch"

  if [ "$DRY_RUN" -eq 1 ]; then
    if git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then
      log "[dry-run] 可应用：$label"
    elif git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "[dry-run] 已应用：$label"
    else
      die "[dry-run] 无法应用：$label"
    fi
    return 0
  fi

  # 幂等：如果反向检查成功，说明补丁已经打过了
  if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
    log "已应用，跳过：$label"
    return 0
  fi

  git -C "$dir" apply "$patch" || die "补丁应用失败：$label"
  log "已应用：$label"
}

main() {
  [ -f "${PROJECT_ROOT}/pubspec.yaml" ] || die "当前目录不是 PiliPlus 仓库：${PROJECT_ROOT}"

  local flutter_root
  flutter_root="$(find_flutter_root)"
  log "Flutter SDK：${flutter_root}"

  local version="unknown"
  if [ -f "${flutter_root}/bin/cache/flutter.version.json" ]; then
    version="$(grep -o '"frameworkVersion"[^,]*' "${flutter_root}/bin/cache/flutter.version.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)"
  fi
  [ -n "$version" ] && log "Flutter 版本：${version}"

  git -C "$flutter_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "Flutter SDK 不是 git 仓库，无法应用补丁：${flutter_root}"

  if [ "$NO_RESET" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log "重置 Flutter SDK 到干净状态：git reset --hard HEAD"
    git -C "$flutter_root" reset --hard HEAD >/dev/null
  fi

  # 与 lib/scripts/patch.ps1 android 的顺序保持一致
  local -a flutter_patches=(
    "lib/scripts/modal_barrier.patch"
    "lib/scripts/text_selection.patch"
    "lib/scripts/mouse_cursor.patch"
    "lib/scripts/image_anim.patch"
    "lib/scripts/layout_builder.patch"
    "lib/scripts/navigation_drawer.patch"
    "lib/scripts/popup_menu.patch"
    "lib/scripts/fab.patch"
    "lib/scripts/null_safety_for_selectable_region.patch"
    "lib/scripts/selectable_region.patch"
    "lib/scripts/editable_text.patch"
    "lib/scripts/text_field.patch"
    "lib/scripts/scroll_position.patch"
    "lib/scripts/scrollable.patch"
    "lib/scripts/scrollable_gesture.patch"
    "lib/scripts/draggable_scrollable_sheet.patch"
    "lib/scripts/scaffold.patch"
    "lib/scripts/text.patch"
    "lib/scripts/text_painter.patch"
    "lib/scripts/sliver.patch"
    "lib/scripts/refresh_indicator.patch"
    "lib/scripts/bottom_sheet_android.patch"
    "lib/scripts/scroll_view.patch"
    "lib/scripts/navigator.patch"
  )

  local p
  for p in "${flutter_patches[@]}"; do
    apply_patch "$flutter_root" "${PROJECT_ROOT}/${p}" "$p"
  done

  # 找到当前 pub 实际使用的 material_ui 目录，兼容 pub.dev / pub.flutter-io.cn / TUNA 等源
  local material_ui_dir=""
  local package_config="${PROJECT_ROOT}/.dart_tool/package_config.json"
  if [ -f "$package_config" ] && command -v python3 >/dev/null 2>&1; then
    material_ui_dir="$(python3 - "$package_config" <<'PY'
import json, sys, urllib.parse
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
for pkg in data.get('packages', []):
    if pkg.get('name') == 'material_ui':
        root = pkg.get('rootUri', '')
        if root.startswith('file://'):
            root = urllib.parse.unquote(root[7:])
        print(root)
        break
PY
)"
  fi

  if [ -z "$material_ui_dir" ] || [ ! -d "$material_ui_dir" ]; then
    material_ui_dir="$(find "${HOME}/.pub-cache/hosted" -maxdepth 3 -type d -name 'material_ui-*' 2>/dev/null | sort | tail -n1 || true)"
  fi
  [ -n "$material_ui_dir" ] && [ -d "$material_ui_dir" ] \
    || die "未找到 material_ui 包，请先执行：fvm flutter pub get"
  log "material_ui：${material_ui_dir}"

  local -a material_patches=(
    "lib/scripts/material/modal_barrier_material.patch"
    "lib/scripts/material/navigation_drawer.patch"
    "lib/scripts/material/popup_menu.patch"
    "lib/scripts/material/fab.patch"
    "lib/scripts/material/text_field.patch"
    "lib/scripts/material/scaffold.patch"
    "lib/scripts/material/refresh_indicator.patch"
    "lib/scripts/material/tabs.patch"
    "lib/scripts/material/bottom_sheet_android.patch"
  )

  for p in "${material_patches[@]}"; do
    apply_patch "$material_ui_dir" "${PROJECT_ROOT}/${p}" "$p"
  done

  log "Android 补丁全部处理完成。"
  if [ "$DRY_RUN" -eq 0 ]; then
    log "现在可以执行：fvm flutter clean && fvm flutter build apk --release"
  fi
}

main
