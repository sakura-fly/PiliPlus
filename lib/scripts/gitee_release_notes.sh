#!/usr/bin/env bash
# =============================================================================
# PiliPlus —— 生成 Release 说明（Gitee Go 流水线专用）
#
# 输出格式与 .github/workflows/build.yml 的 "Generate release notes" 完全一致：
#   1) ## What's Changed —— 上游 PiliPlus 最新提交之后的本仓库提交（排除 merge）
#   2) ## PiliPlus New Release: <name> —— 上游最新 Release 的说明（过滤噪声段落）
#   3) 两部分都为空时输出 "Initial release"
#
# 由 .workflow/android-pipeline.yml 在构建完成后调用，产物 release_notes.md
# 通过 lib/scripts/gitee_release_upload.sh --body-file 发布到 Gitee Release。
#
# 与 GitHub 侧唯一的差异是网络容错（不改变输出内容）：
#   Gitee 执行器访问 api.github.com 不稳定，每次请求都带超时，并依次尝试
#   直连 -> ghfast.top 代理 -> 降级（近 30 天提交 / 跳过上游 Release 说明），
#   保证 GitHub API 不可达时流水线仍能生成说明并继续发布。
#
# 用法：bash lib/scripts/gitee_release_notes.sh [输出文件] [上次发布记录文件]
# =============================================================================
set -uo pipefail

OUT="${1:-release_notes.md}"
LAST_RELEASE_FILE="${2:-.piliplus_last_release}"
UPSTREAM="bggRGjQaUbCoE/PiliPlus"

# GitHub API：直连优先，代理兜底；超时或失败返回非 0，由调用方降级处理
github_api() {
  local path="$1" url body
  for url in \
    "https://api.github.com/repos/${UPSTREAM}/${path}" \
    "https://ghfast.top/https://api.github.com/repos/${UPSTREAM}/${path}"
  do
    body="$(curl -fsSL --connect-timeout 8 --max-time 25 "$url" 2>/dev/null || true)"
    if [ -n "$body" ]; then
      printf '%s' "$body"
      return 0
    fi
  done
  return 1
}

# 从 stdin 的 JSON 中取值；python3 不可用或解析失败时返回空
py_get() {
  local code="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys, json; d = json.load(sys.stdin); ${code}" 2>/dev/null || true
  fi
}

echo "==> 生成 Release 说明: ${OUT}"

# ---- Part 1: 上游最新提交时间之后的本仓库提交 ----
COMMITS_JSON="$(github_api "commits/main" || true)"
# 第一个 API 就完全不可达时，不再为第二个 API 重复两轮超时
# （Gitee 执行器访问 api.github.com 通常不通，每轮超时最长 25s）
GITHUB_REACHABLE=1
if [ -z "$COMMITS_JSON" ]; then
  GITHUB_REACHABLE=0
  echo "警告：GitHub API 不可达，跳过上游 Release 说明" >&2
fi
PILIPLUS_COMMIT_DATE="$(printf '%s' "$COMMITS_JSON" | py_get "print(d['commit']['committer']['date'])")"
if [ -z "$PILIPLUS_COMMIT_DATE" ]; then
  # GitHub API 不可达或解析失败：退化为近 30 天窗口，保证始终有变更摘要
  PILIPLUS_COMMIT_DATE="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  echo "警告：无法获取上游 PiliPlus 最新提交时间，改用近 30 天窗口" >&2
else
  echo "上游 PiliPlus 最新提交时间: ${PILIPLUS_COMMIT_DATE}"
fi
COMMITS="$(git log --no-merges --pretty=format:"- %s (%h)" --since="$PILIPLUS_COMMIT_DATE" HEAD 2>/dev/null || true)"

# ---- Part 2: 上游 PiliPlus 最新 Release ----
if [ "$GITHUB_REACHABLE" -eq 1 ]; then
  LATEST_RELEASE="$(github_api "releases/latest" || true)"
else
  LATEST_RELEASE=""
fi
RELEASE_TAG="$(printf '%s' "$LATEST_RELEASE" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
RELEASE_BODY_RAW="$(printf '%s' "$LATEST_RELEASE" | py_get "print(d.get('body') or '')" || true)"
RELEASE_NAME="$(printf '%s' "$LATEST_RELEASE" | py_get "print((d.get('name') or '').split(chr(10))[0])" || true)"

# 与 build.yml 相同的噪声过滤
if [ -n "$RELEASE_BODY_RAW" ]; then
  RELEASE_BODY="$(printf '%s' "$RELEASE_BODY_RAW" \
    | sed '/^### Contributors$/,$d' \
    | sed '/^Assets/d' \
    | sed '/^Loading$/d' \
    | sed '/^### Uh oh!$/,$d' \
    | sed '/^All reactions$/,$d')"
else
  RELEASE_BODY=""
fi

# 与 build.yml 一致：读取上次同步过的上游 tag（Gitee 每次全新克隆，通常为空）
LAST_RELEASE=""
if [ -f "$LAST_RELEASE_FILE" ]; then
  LAST_RELEASE="$(cat "$LAST_RELEASE_FILE")"
fi

{
  if [ -n "$COMMITS" ]; then
    echo "## What's Changed"
    echo ""
    echo "$COMMITS"
    echo ""
  fi

  if [ "$RELEASE_TAG" != "$LAST_RELEASE" ] && [ -n "$RELEASE_TAG" ] && [ -n "$RELEASE_BODY" ]; then
    echo "## PiliPlus New Release: ${RELEASE_NAME}"
    echo ""
    echo "$RELEASE_BODY"
    echo ""
  fi

  # 两部分都没有内容时的默认说明
  if [ -z "$COMMITS" ] && { [ "$RELEASE_TAG" = "$LAST_RELEASE" ] || [ -z "$RELEASE_TAG" ] || [ -z "$RELEASE_BODY" ]; }; then
    echo "Initial release"
  fi
} > "$OUT"

echo "==> 已写入 ${OUT}（$(wc -c < "$OUT") 字节）"
cat "$OUT"
exit 0
