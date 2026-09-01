#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— 上传构建产物到 Gitee Release
# 由 .github/workflows/*.yml 在打包完成后调用（Gitee 仓库: sakura-fly/PiliPlus）。
# 依赖：curl（ubuntu / macos / windows Git Bash 均自带）。
#
# 环境变量：
#   GITEE_TOKEN   Gitee 私人令牌。在 GitHub 仓库 Settings -> Secrets 添加，
#                 命名 GITEE_TOKEN，令牌需勾选 projects 权限。
#                 未配置时脚本打印警告并以 0 退出（跳过上传）。
#
# 参数：
#   --repo owner/repo   目标 Gitee 仓库，如 sakura-fly/PiliPlus
#   --tag  vX.Y.Z       版本号 / 标签（空则跳过）
#   --files "glob"      待上传文件通配符，可重复传入
#
# 行为：按 tag 查找 Gitee Release，不存在则自动创建；上传前对比已有附件，
#       同名文件自动跳过（幂等，可重复运行）。
# =============================================================================
set -euo pipefail

API="https://gitee.com/api/v5"
REPO=""
TAG=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --tag)    TAG="${2:-}"; shift 2 ;;
    --files)  FILES+=("${2:-}"); shift 2 ;;
    *) echo "错误：未知参数 $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${GITEE_TOKEN:-}" ]]; then
  echo "警告：未配置 GITEE_TOKEN（仓库 Secrets），跳过上传到 Gitee Release"
  exit 0
fi
if [[ -z "$REPO" ]]; then
  echo "错误：必须提供 --repo 参数" >&2
  exit 2
fi
if [[ -z "$TAG" ]]; then
  echo "警告：未提供 tag，跳过上传到 Gitee Release"
  exit 0
fi

echo "==> Gitee Release 上传: $REPO @ $TAG"

# ---- 1. 获取或创建 Release ----
RELEASE_ID=""
GET_JSON="$(curl -fsSL -G "$API/repos/$REPO/releases/tags/$TAG" \
  --data-urlencode "access_token=$GITEE_TOKEN" 2>/dev/null || true)"
if [[ -n "$GET_JSON" ]]; then
  RELEASE_ID="$(printf '%s' "$GET_JSON" \
    | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*' || true)"
fi

if [[ -z "$RELEASE_ID" ]]; then
  echo "==> Release $TAG 不存在，尝试创建..."
  BODY="{\"access_token\":\"$GITEE_TOKEN\",\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":\"PiliPlus $TAG\""
  if [[ -n "${GITHUB_SHA:-}" ]]; then
    BODY="$BODY,\"target_commitish\":\"$GITHUB_SHA\""
  fi
  BODY="$BODY,\"prerelease\":false}"
  CREATE_JSON="$(curl -fsSL -X POST "$API/repos/$REPO/releases" \
    -H 'Content-Type: application/json;charset=UTF-8' \
    --data "$BODY")"
  RELEASE_ID="$(printf '%s' "$CREATE_JSON" \
    | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*' || true)"
  if [[ -z "$RELEASE_ID" ]]; then
    echo "错误：创建 Gitee Release 失败，响应：" >&2
    echo "$CREATE_JSON" >&2
    exit 1
  fi
fi
echo "==> Release ID: $RELEASE_ID"

# ---- 2. 获取已存在附件名（用于幂等跳过）----
EXISTING="$(curl -fsSL -G "$API/repos/$REPO/releases/$RELEASE_ID/attach_files" \
  --data-urlencode "access_token=$GITEE_TOKEN" \
  --data-urlencode "per_page=100" 2>/dev/null \
  | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/' || true)"

exists() {
  local name="$1"
  while IFS= read -r line; do
    [[ "$line" == "$name" ]] && return 0
  done <<< "$EXISTING"
  return 1
}

# ---- 3. 上传文件 ----
UPLOADED=0
SKIPPED=0
for GLOB in "${FILES[@]}"; do
  for FILE in $GLOB; do
    [[ -f "$FILE" ]] || continue
    NAME="$(basename "$FILE")"
    if exists "$NAME"; then
      echo "==> 已存在，跳过: $NAME"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    echo "==> 上传: $NAME"
    curl -fsSL -X POST "$API/repos/$REPO/releases/$RELEASE_ID/attach_files" \
      -H 'Expect:' \
      -F "access_token=$GITEE_TOKEN" \
      -F "file=@$FILE"
    echo ""
    UPLOADED=$((UPLOADED + 1))
  done
done

echo "==> 完成：上传 $UPLOADED 个文件，跳过 $SKIPPED 个已存在文件。"
