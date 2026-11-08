# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：认证按上游官方选项关掉（认证由云吞网关承担），应用侧没有用户体系，写 IDENTITY_NA=1。
# 数据：data_write 用随机标记建一条笔记并把标记写进 $SMOKE_STATE，data_check 读回核对。
#
# 钩子可用：SMOKE_STATE/SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER/SMOKE_BASE/SMOKE_TOKEN/SMOKE_INSTANCE
# 与 web_get、dweb。

web_assert() { grep -q 'Trilium Notes'; }   # 客户端 HTML shell 的 <title>

# Trilium 首次启动后文档还没建：先走一次应用自己的设置向导接口（新实例免鉴权；已建过文档时
# 返回 401 "App already initialized."，重跑幂等），文档建好后 /bootstrap 才会签发 CSRF。
# /api/* 的 POST 一律要 CSRF（apiRoute 恒加 csrfMiddleware）：GET /bootstrap 领
# trilium-csrf cookie，再带回请求头。
marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/trilium-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() {
  local resp note_id marker csrf
  [[ -n "$SMOKE_JAR" && -n "$SMOKE_WEB_URL" ]] || { echo "拿不到会话或网页地址"; return 1; }

  resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
    -X POST "${SMOKE_WEB_URL%/}/api/setup/new-document?skipDemoDb")" || { echo "设置向导接口请求失败"; return 1; }
  case "$resp" in
    2*) : ;;
    401) : ;;  # 文档已存在（重装/重跑），照常用
    *) echo "建文档返回 $resp"; return 1 ;;
  esac

  resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -o /dev/null -w '%{http_code}' "${SMOKE_WEB_URL%/}/bootstrap")" ||
    { echo "取 bootstrap 失败"; return 1; }
  csrf="$(awk '$6=="trilium-csrf"{print $NF; exit}' "$SMOKE_JAR")"
  [[ -n "$csrf" ]] || { echo "bootstrap 后没有 trilium-csrf cookie（GET /bootstrap 返回 $resp）"; return 1; }

  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' \
    -d "{\"title\":\"云吞冒烟 $marker\",\"content\":\"<p>云吞冒烟标记 $marker</p>\",\"type\":\"text\"}" \
    "${SMOKE_WEB_URL%/}/api/notes/root/children?target=into")" || { echo "建笔记失败：$resp"; return 1; }
  note_id="$(jq -r '.note.noteId // empty' <<<"$resp")"
  [[ -n "$note_id" ]] || { echo "响应里没有 noteId：$(head -c 200 <<<"$resp")"; return 1; }
  printf 'TRILIUM_PROBE_NOTE_ID=%s\nTRILIUM_PROBE_MARKER=%s\n' "$note_id" "$marker" >"$(marker_file)"
}

data_check() {
  local note_id marker marker_path resp
  marker_path="$(marker_file)"
  [[ -s "$marker_path" ]] || { echo "没有数据标记文件 $marker_path"; return 1; }
  note_id="$(sed -n 's/^TRILIUM_PROBE_NOTE_ID=//p' "$marker_path")"
  marker="$(sed -n 's/^TRILIUM_PROBE_MARKER=//p' "$marker_path")"
  [[ -n "$note_id" && -n "$marker" ]] || { echo "标记文件不完整：$(head -c 120 "$marker_path")"; return 1; }

  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "${SMOKE_WEB_URL%/}/api/notes/$note_id")" ||
    { echo "读不回笔记 $note_id：$resp"; return 1; }
  grep -qF "$marker" <<<"$resp" ||
    { echo "笔记里找不到标记 $marker：$(head -c 200 <<<"$resp")"; return 1; }
}

# 认证由网关承担（清单里 TRILIUM_GENERAL_NOAUTHENTICATION）：应用侧没有“当前用户”接口可断言，
# 主人能打开由 web_assert 和网关对匿名请求的 401 证明。
export IDENTITY_NA=1
export SMOKE_NOTE="认证按上游选项交给网关（无应用内登录），应用没有用户体系可断言；主人会话能打开应用、网关拒绝匿名请求由网页项证明"
