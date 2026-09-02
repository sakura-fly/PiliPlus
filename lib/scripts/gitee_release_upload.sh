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
COMMITISH=""
KEEP=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --tag)       TAG="${2:-}"; shift 2 ;;
    --commitish) COMMITISH="${2:-}"; shift 2 ;;
    --files)     FILES+=("${2:-}"); shift 2 ;;
    --keep)      KEEP="${2:-}"; shift 2 ;;
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
  # Gitee 要求 target_commitish 必填，且必须是 Gitee 仓库中真实存在的分支名或 commit SHA；
  # 未显式传入时自动读取 Gitee 仓库默认分支（GitHub 的 SHA 在 Gitee 仓库中不存在，会返回 400）
  if [[ -z "$COMMITISH" ]]; then
    REPO_JSON="$(curl -fsSL -G "$API/repos/$REPO" \
      --data-urlencode "access_token=$GITEE_TOKEN" 2>/dev/null || true)"
    COMMITISH="$(printf '%s' "$REPO_JSON" \
      | grep -o '"default_branch"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/.*"default_branch"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/' | head -1 || true)"
    echo "==> 自动获取 Gitee 默认分支: ${COMMITISH:-<未获取到>}"
  fi
  if [[ -z "$COMMITISH" ]]; then
    echo "错误：无法确定 target_commitish（请用 --commitish 显式指定 Gitee 仓库的分支名）" >&2
    exit 1
  fi
  BODY="{\"access_token\":\"$GITEE_TOKEN\",\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":\"PiliPlus $TAG\",\"target_commitish\":\"$COMMITISH\",\"prerelease\":false}"
  CREATE_TMP="$(mktemp)"
  CREATE_CODE="$(curl -sS -o "$CREATE_TMP" -w '%{http_code}' -X POST "$API/repos/$REPO/releases" \
    -H 'Content-Type: application/json;charset=UTF-8' \
    --data "$BODY" || true)"
  CREATE_JSON="$(cat "$CREATE_TMP" 2>/dev/null || true)"
  rm -f "$CREATE_TMP"
  if [[ "$CREATE_CODE" != 2* ]]; then
    echo "错误：创建 Gitee Release 失败（HTTP ${CREATE_CODE}），响应：" >&2
    echo "$CREATE_JSON" >&2
    exit 1
  fi
  RELEASE_ID="$(printf '%s' "$CREATE_JSON" \
    | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*' || true)"
  if [[ -z "$RELEASE_ID" ]]; then
    echo "错误：创建 Gitee Release 失败（HTTP ${CREATE_CODE}），响应：" >&2
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

# ---- 3. 上传文件（带超时与自动重试） ----
UPLOADED=0
SKIPPED=0

# 上传单个附件；失败自动重试（Gitee 上传不稳定/限流，重试+退避提高成功率）
upload_file() {
  local file="$1" attempt delay=5 code body tmp encoded_name
  local name
  name="$(basename "$file")"
  # Gitee 会把 multipart filename 中的 + 按 URL 空格解码，转义为 %2B 以保留加号
  encoded_name="${name//+/%2B}"
  for ((attempt = 1; attempt <= 3; attempt++)); do
    tmp="$(mktemp)"
    code="$(curl -sS -o "$tmp" -w '%{http_code}' --connect-timeout 30 --max-time 900 \
      -X POST "$API/repos/$REPO/releases/$RELEASE_ID/attach_files" \
      -H 'Expect:' \
      -F "access_token=$GITEE_TOKEN" \
      -F "file=@$file;filename=$encoded_name" || true)"
    body="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    if [[ "$code" == 2* ]]; then
      echo "==> 上传成功: $name"
      return 0
    fi
    echo "警告：上传 $name 失败（HTTP ${code}，第 ${attempt}/3 次）" >&2
    if [[ -n "$body" ]]; then
      echo "Gitee 响应: $body" >&2
    fi
    if [[ $attempt -lt 3 ]]; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  echo "错误：上传 $name 最终失败" >&2
  return 1
}

FAILED=0
for GLOB in "${FILES[@]}"; do
  for FILE in $GLOB; do
    [[ -f "$FILE" ]] || continue
    NAME="$(basename "$FILE")"
    if exists "$NAME"; then
      echo "==> 已存在，跳过: $NAME"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if ! upload_file "$FILE"; then
      FAILED=1
    else
      UPLOADED=$((UPLOADED + 1))
    fi
  done
done

echo "==> 完成：上传 $UPLOADED 个文件，跳过 $SKIPPED 个已存在文件。"
if [[ "$FAILED" -eq 1 ]]; then
  echo "错误：部分文件上传失败" >&2
  exit 1
fi

# ---- 4. 清理旧 Release（仅保留最近 KEEP 个，默认不清理） ----
cleanup_old_releases() {
  local keep="$1" list ids id idx=0
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [[ "$keep" -eq 0 ]]; then
    return 0
  fi
  echo "==> 清理旧 Release：仅保留最近 $keep 个"
  list="$(curl -fsSL -G "$API/repos/$REPO/releases" \
    --data-urlencode "access_token=$GITEE_TOKEN" \
    --data-urlencode "per_page=100" 2>/dev/null || true)"
  # 只取 release 外层 id（按创建时间倒序），author.id 等内嵌 id 不匹配
  ids="$(printf '%s' "$list" \
    | grep -oE '\{"id":[0-9]+,"tag_name"' \
    | grep -oE '[0-9]+')"
  for id in $ids; do
    idx=$((idx + 1))
    if [[ $idx -le "$keep" ]]; then
      continue
    fi
    echo "==> 删除旧 Release #$id（保留最近 ${keep} 个）"
    curl -fsSL -X DELETE "$API/repos/$REPO/releases/$id" \
      --data-urlencode "access_token=$GITEE_TOKEN" >/dev/null 2>&1 \
      || echo "警告：删除 Release #$id 失败" >&2
  done
}

cleanup_old_releases "$KEEP"
echo "==> 完成"
