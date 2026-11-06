# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：认证按上游官方选项关掉（认证由云吞网关承担），应用侧没有用户体系，写 IDENTITY_NA=1。
# 数据：data_write 用随机标记建一条笔记，data_check 重装后读回核对。两者都写才跑。
#
# dev.sh probes（SMOKE_*）和 e2e/smoke.sh（E2E_*）两个上下文共用，会话与地址按上下文取。

probe_jar() { printf '%s' "${SMOKE_JAR:-${E2E_JAR:-}}"; }
probe_base() { printf '%s' "${SMOKE_WEB_URL:-${E2E_WEB_URL:-}}"; }
# SMOKE_STATE 在 dev 里是目录（.wonton），在 e2e 里是文件（work/<名>.state）：目录里放专属文件，
# 文件旁边放兄弟文件，两种上下文都能读写。
probe_stash() {
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/trilium-data.env"; else printf '%s' "$SMOKE_STATE.trilium-data"; fi
}

web_assert() { grep -q 'Trilium Notes'; }   # 客户端 HTML shell 的 <title>

# Trilium 首次启动后文档还没建：先走一次应用自己的设置向导接口（新实例免鉴权；已建过文档时
# 返回 401 "App already initialized."，重跑幂等），文档建好后 /bootstrap 才会签发 CSRF。
# /api/* 的 POST 一律要 CSRF（apiRoute 恒加 csrfMiddleware）：GET /bootstrap 领
# trilium-csrf cookie，再带回请求头。
data_write() {
  local jar base stash resp note_id marker csrf
  jar="$(probe_jar)"; base="$(probe_base)"
  [[ -n "$jar" && -n "$base" ]] || { echo "拿不到会话或网页地址"; return 1; }

  resp="$(curl -sS --noproxy '*' -b "$jar" -o /dev/null -w '%{http_code}' \
    -X POST "$base/api/setup/new-document?skipDemoDb")" || { echo "设置向导接口请求失败"; return 1; }
  case "$resp" in
    2*) : ;;
    401) : ;;  # 文档已存在（重装/重跑），照常用
    *) echo "建文档返回 $resp"; return 1 ;;
  esac

  resp="$(curl -sS --noproxy '*' -b "$jar" -c "$jar" -o /dev/null -w '%{http_code}' "$base/bootstrap")" ||
    { echo "取 bootstrap 失败"; return 1; }
  csrf="$(awk '$6=="trilium-csrf"{print $NF; exit}' "$jar")"
  [[ -n "$csrf" ]] || { echo "bootstrap 后没有 trilium-csrf cookie（GET /bootstrap 返回 $resp）"; return 1; }

  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' \
    -d "{\"title\":\"云吞冒烟 $marker\",\"content\":\"<p>云吞冒烟标记 $marker</p>\",\"type\":\"text\"}" \
    "$base/api/notes/root/children?target=into")" || { echo "建笔记失败：$resp"; return 1; }
  note_id="$(jq -r '.note.noteId // empty' <<<"$resp")"
  [[ -n "$note_id" ]] || { echo "响应里没有 noteId：$(head -c 200 <<<"$resp")"; return 1; }
  printf 'TRILIUM_PROBE_NOTE_ID=%s\nTRILIUM_PROBE_MARKER=%s\n' "$note_id" "$marker" >"$(probe_stash)"
}

data_check() {
  local jar base stash note_id marker resp
  jar="$(probe_jar)"; base="$(probe_base)"
  stash="$(probe_stash)"
  [[ -f "$stash" ]] || { echo "没有数据标记文件 $stash"; return 1; }
  note_id="$(sed -n 's/^TRILIUM_PROBE_NOTE_ID=//p' "$stash")"
  marker="$(sed -n 's/^TRILIUM_PROBE_MARKER=//p' "$stash")"
  [[ -n "$note_id" && -n "$marker" ]] || { echo "标记文件不完整：$(head -c 120 "$stash")"; return 1; }

  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" "$base/api/notes/$note_id")" ||
    { echo "读不回笔记 $note_id：$resp"; return 1; }
  grep -qF "$marker" <<<"$resp" ||
    { echo "笔记里找不到标记 $marker：$(head -c 200 <<<"$resp")"; return 1; }
}

# 认证由网关承担（清单里 TRILIUM_GENERAL_NOAUTHENTICATION）：应用侧没有“当前用户”接口可断言，
# 主人能打开由 web_assert 和网关对匿名请求的 401 证明。dev 探针读 SMOKE_NOTE，e2e 读 E2E_NOTE。
export IDENTITY_NA=1
export SMOKE_NOTE="认证按上游选项交给网关（无应用内登录），应用没有用户体系可断言；主人会话能打开应用、网关拒绝匿名请求由网页项证明"
export E2E_NOTE="$SMOKE_NOTE"
