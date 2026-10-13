#!/usr/bin/env bash
# set-proxy.sh —— 把代理写进各工具**自己的配置文件**，一次到位，不依赖 source / shell 函数 / 任何仓库。
#
#   ./set-proxy.sh tx|sh|<url>   写代理：rc 四文件 + git + npm + curl + wget + pip
#   ./set-proxy.sh off           撤销（rc 块删除、各工具配置清除；实测逐字节还原）
#   ./set-proxy.sh show          打印每一处当前值 + 端到端自检
#
# 开关（不点名就不生效）：
#   --env    /etc/environment    给**只认环境变量**的程序：python requests/urllib、cron、新登录会话（需 root）
#   --go     go env -w GOPROXY=https://goproxy.cn,direct   go get 不用翻墙（写配置文件，不吃环境变量）
#   --everything  = --env --go
#   --sweep       顺带清掉 rc 里残留的 `source ~/.sh-tx-proxy/proxy.sh`
#
# 默认（不带开关）**完全不碰 /etc、不需要 root**。
# 覆盖默认地址：PROXY_SH / PROXY_TX / NO_PROXY_LIST / GOPROXY_MIRROR
# 演练（不碰真系统）：SET_PROXY_HOME=/tmp/h SET_PROXY_ETC_DIR=/tmp/e bash set-proxy.sh tx --everything
#
# 写到的位置：
#   ~/.bashrc   交互 bash              ~/.zshrc   交互 zsh
#   ~/.zshenv   所有 zsh（含 zsh -c）   ~/.profile 登录 shell（bash -l / sh -l）
#   ~/.gitconfig http.proxy/https.proxy   ~/.npmrc proxy/https-proxy/noproxy
#   ~/.curlrc proxy/noproxy               ~/.wgetrc use_proxy/http_proxy/no_proxy
#   ~/.config/pip/pip.conf global.proxy
# 注：`bash -c` / bash 脚本读不到 rc（Kali 的 ~/.bashrc 对非交互提前 return）→ 用 --env。

set -uo pipefail

PROXY_SH="${PROXY_SH:-http://10.10.2.14:7890}"
PROXY_TX="${PROXY_TX:-http://10.100.36.162:7890}"
NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12}"
GOPROXY_MIRROR="${GOPROXY_MIRROR:-https://goproxy.cn,direct}"

BEGIN='# ---- proxy (managed by set-proxy.sh) ----'
END='# ---- proxy end ----'
LEGACY='sh-tx-proxy/proxy.sh'
ETC_DIR="${SET_PROXY_ETC_DIR:-/etc}"

FLAG_ENV=0; FLAG_GO=0; SWEEP=0; ACTION=""; URL=""

for a in "$@"; do
    case "$a" in
        --env)        FLAG_ENV=1 ;;
        --go)         FLAG_GO=1 ;;
        --everything) FLAG_ENV=1; FLAG_GO=1 ;;
        --sweep)      SWEEP=1 ;;
        tx)           ACTION=set; URL="$PROXY_TX" ;;
        sh)           ACTION=set; URL="$PROXY_SH" ;;
        off|unset|rm) ACTION=off ;;
        show|status)  ACTION=show ;;
        http://*|https://*) ACTION=set; URL="$a" ;;
        -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done
[ -n "$ACTION" ] || { echo "用法: $0 tx|sh|off|show|<url> [--env --go --everything] [--sweep]" >&2; exit 2; }

if [ -n "${SET_PROXY_HOME:-}" ]; then HOME="$SET_PROXY_HOME"; fi
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    [ -n "$HOME" ] || { echo "HOME 为空且查不到家目录，放弃。可显式：HOME=/root bash $0 ..." >&2; exit 1; }
fi
[ -d "$HOME" ] || { echo "HOME=$HOME 不是目录，放弃。" >&2; exit 1; }
if [ "$ACTION" != show ] && [ ! -w "$HOME" ]; then echo "HOME=$HOME 不可写，放弃（要不要 sudo -H？）" >&2; exit 1; fi

have() { command -v "$1" >/dev/null 2>&1; }
# 按「显示宽度」对齐（中文算 2 列；wc -L 给的正是显示宽度）
p()    { local w; w=$(printf '%s' "$1" | wc -L); printf '%s%*s %s\n' "$1" "$(( 24 > w ? 24 - w : 1 ))" '' "$2"; }
say()  { printf '%s\n' "$*"; }

# ---- 在文件里替换/删除标记块 --------------------------------------------------
block_edit() {   # $1=文件 $2=set 时要写的多行内容 $3=标签
    local file="$1" content="$2" label="${3:-$(basename "$1")}" tmp="$1.tmp-set-proxy"
    if [ ! -e "$file" ] && ! : > "$file" 2>/dev/null; then p "$label" "跳过：无法创建（需要 root？）"; return 1; fi
    [ -w "$file" ] || { p "$label" "跳过：不可写（需要 sudo）"; return 1; }
    [ -f "$file.bak-set-proxy" ] || cp -a "$file" "$file.bak-set-proxy" 2>/dev/null
    awk -v b="$BEGIN" -v e="$END" 'index($0,b){inblk=1;next} inblk && index($0,e){inblk=0;next} inblk{next} {print}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ "$ACTION" = set ]; then
        [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ] && printf '\n' >> "$tmp"
        printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END" >> "$tmp"
    fi
    mv "$tmp" "$file" || { p "$label" "写入失败"; return 1; }
    # off 后文件被清空（原本不存在、脚本建的）→ 连文件带备份删掉，不留 0 字节空壳
    if [ "$ACTION" != set ] && [ ! -s "$file" ]; then
        rm -f "$file" "$file.bak-set-proxy"; p "$label" "已清除（原本无此文件）"; return 0
    fi
    p "$label" "$( [ "$ACTION" = set ] && echo "$URL" || echo "已清除" )"
}

# ---- 块内容 ------------------------------------------------------------------
shell_block() {
    printf 'export http_proxy="%s"\nexport https_proxy="$http_proxy"\nexport all_proxy="$http_proxy"\n' "$URL"
    printf 'export HTTP_PROXY="$http_proxy"\nexport HTTPS_PROXY="$http_proxy"\nexport ALL_PROXY="$http_proxy"\n'
    printf 'export no_proxy="%s"\nexport NO_PROXY="$no_proxy"\n' "$NO_PROXY_LIST"
}
# /etc/environment 由 pam_env 解析，不做变量展开 → 必须写完整字面值
env_block() {
    printf 'http_proxy=%s\nhttps_proxy=%s\nall_proxy=%s\n' "$URL" "$URL" "$URL"
    printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nALL_PROXY=%s\n' "$URL" "$URL" "$URL"
    printf 'no_proxy=%s\nNO_PROXY=%s\n' "$NO_PROXY_LIST" "$NO_PROXY_LIST"
}
curl_block() { printf 'proxy = %s\nnoproxy = "%s"\n' "$URL" "$NO_PROXY_LIST"; }
wget_block() { printf 'use_proxy=yes\nhttp_proxy = %s\nhttps_proxy = %s\nno_proxy = "%s"\n' "$URL" "$URL" "$NO_PROXY_LIST"; }

rc_sweep() {
    local file="$1" n
    [ -f "$file" ] || return 0
    n=$(grep -c "$LEGACY" "$file" 2>/dev/null); n=${n:-0}
    [ "$n" -gt 0 ] || return 0
    [ -f "$file.bak-set-proxy" ] || cp -a "$file" "$file.bak-set-proxy"
    grep -v "$LEGACY" "$file" > "$file.tmp-set-proxy" && mv "$file.tmp-set-proxy" "$file"
    p "$(basename "$file")" "已移除 $n 行 proxy.sh 引用"
}

# ---- 各工具 ------------------------------------------------------------------
git_apply() {
    have git || { p "git" "跳过：没装 git"; return; }
    if [ "$ACTION" = set ]; then git config --global http.proxy "$URL"; git config --global https.proxy "$URL"
    else git config --global --unset http.proxy 2>/dev/null; git config --global --unset https.proxy 2>/dev/null; fi
    p "git (~/.gitconfig)" "$(git config --global --get http.proxy 2>/dev/null || echo 未配置)"
}
npm_apply() {
    have npm || { p "npm" "跳过：没装 npm"; return; }
    if [ "$ACTION" = set ]; then npm config set proxy "$URL" https-proxy "$URL" noproxy "$NO_PROXY_LIST" >/dev/null 2>&1
    else npm config delete proxy >/dev/null 2>&1; npm config delete https-proxy >/dev/null 2>&1; npm config delete noproxy >/dev/null 2>&1; fi
    p "npm (~/.npmrc)" "$( [ "$ACTION" = set ] && echo "$URL" || echo "已清除 → $(npm config get proxy 2>/dev/null)" )"
}
pip_apply() {
    have python3 || { p "pip" "跳过：没装 python3"; return; }
    if [ "$ACTION" = set ]; then
        python3 -m pip config set global.proxy "$URL" >/dev/null 2>&1
        python3 -m pip config set global.noproxy "\"$NO_PROXY_LIST\"" >/dev/null 2>&1
        p "pip (pip.conf)" "$URL"
    else
        python3 -m pip config unset global.proxy >/dev/null 2>&1
        python3 -m pip config unset global.noproxy >/dev/null 2>&1
        local pc="$HOME/.config/pip/pip.conf"   # pip 撤完会留空壳（0 字节或只剩 [global]），删掉
        if [ -f "$pc" ] && { [ ! -s "$pc" ] || ! grep -qE '^[[:space:]]*[a-z]' "$pc"; }; then
            rm -f "$pc"; rmdir "$HOME/.config/pip" 2>/dev/null
        fi
        p "pip (pip.conf)" "已清除"
    fi
}
go_apply() {
    [ "$FLAG_GO" = 1 ] || return 0
    have go || { p "go" "跳过：没装 go"; return; }
    if [ "$ACTION" = set ]; then
        go env -w GOPROXY="$GOPROXY_MIRROR" && p "go (GOPROXY)" "$GOPROXY_MIRROR（go get 不用翻墙）"
    else
        go env -u GOPROXY >/dev/null 2>&1
        local genv; genv="$(go env GOENV 2>/dev/null)"
        [ -n "$genv" ] && [ -f "$genv" ] && [ ! -s "$genv" ] && rm -f "$genv"   # 空 env 文件删掉
        p "go (GOPROXY)" "$(go env GOPROXY)"
    fi
}
etcenv_apply() {
    [ "$FLAG_ENV" = 1 ] || return 0
    block_edit "$ETC_DIR/environment" "$(env_block)" "/etc/environment"
    [ "$ACTION" = set ] && say "  ↳ 只对**之后新登录**的会话生效（ssh/login/su/cron 的 PAM 栈里有 pam_env，实测确认）；已在跑的进程要重启"
}

# ---- show --------------------------------------------------------------------
head_of_block() { [ -f "$1" ] && awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1;next} index($0,e){f=0} f && /proxy/{print;exit}' "$1" | head -1; }
# 只从标记块里取值（避开 rc 文件里历史遗留的注释行，比如 `# export http_proxy=...`）
rc_block_val() {
    local f
    for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.profile"; do
        [ -f "$f" ] || continue
        local v; v="$(awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1;next} index($0,e){f=0;next} f && /^export http_proxy=/{print;exit}' "$f")"
        [ -n "$v" ] && { printf '%s' "${v#export }"; return; }
    done
    printf '未配置'
}
bv() { local v; v="$(head_of_block "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '未配置'; }
show_all() {
    local E="env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY"
    say "== 每一处当前配置 =="
    p "shell rc 块"      "$(for f in .bashrc .zshrc .zshenv .profile; do [ -f "$HOME/$f" ] && grep -qF "$BEGIN" "$HOME/$f" 2>/dev/null && printf '%s ' "$f"; done)"
    p "shell rc 值"      "$(rc_block_val)"
    p "git"              "$(git config --global --get http.proxy 2>/dev/null || echo 未配置)"
    local npmv; npmv="$(npm config get proxy 2>/dev/null)"
    case "$npmv" in null|undefined|"") npmv="未配置" ;; esac
    p "npm"              "$npmv"
    p "curl"             "$(bv "$HOME/.curlrc")"
    p "wget"             "$(bv "$HOME/.wgetrc")"
    local pipv; pipv="$(python3 -m pip config list 2>/dev/null | sed -n "s/^global.proxy='\\(.*\\)'.*/\\1/p" | tr -d '\"')"
    p "pip"              "${pipv:-未配置}"
    p "go GOPROXY"       "$(go env GOPROXY 2>/dev/null || echo n/a)"
    p "/etc/environment" "$(bv "$ETC_DIR/environment")"
    p "当前会话 env"     "${https_proxy:-未设置}"
    local res; res="$(grep -l "$LEGACY" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.profile" 2>/dev/null | tr '\n' ' ')"
    p "旧 proxy.sh 残留" "${res:-无}"

    echo; say "== 端到端自检 =="
    printf '  %-22s %s\n' "curl（读 ~/.curlrc）" "$(curl -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_total}s' https://github.com 2>&1 | tail -1)"
    # python 只认环境变量：有 --env 块就照登录会话那样注入再测；没有就明说为什么跳过
    local penv=""
    [ -f "$ETC_DIR/environment" ] && penv="$(sed -n "/$BEGIN/,/$END/p" "$ETC_DIR/environment" 2>/dev/null | grep -v '^#' | tr '\n' ' ')"
    if [ -n "$penv" ]; then
        printf '  %-22s %s\n' "python（注入 --env）" "$($E $penv python3 -c 'import requests;print(requests.get("https://www.google.com",timeout=10).status_code)' 2>&1 | tail -1 | cut -c1-40)"
    else
        printf '  %-22s %s\n' "python requests" "跳过：只认环境变量，配 --env 后再看（或显式 export 后手动测）"
    fi
    local gr; gr="$(timeout 20 git ls-remote https://github.com/moyu588/sh-tx-proxy.git HEAD 2>&1 | cut -c1-40)"
    printf '  %-22s %s\n' "git ls-remote"      "${gr:-失败/超时（无代理时属正常）}"
    printf '  %-22s %s\n' "内网(应直连)"      "$(curl -sS -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code}' http://10.100.4.43:3425/v1/models 2>&1 | tail -1)"
}

# ---- 主流程 ------------------------------------------------------------------
if [ "$ACTION" = show ]; then show_all; exit 0; fi
say "== $([ "$ACTION" = set ] && echo "写入 $URL" || echo '撤销所有代理配置') =="
if [ "$SWEEP" = 1 ]; then say "-- 清理 sh-tx-proxy 残留引用 --"; for f in .bashrc .zshrc .zshenv .zprofile .profile; do rc_sweep "$HOME/$f"; done; fi

# 四个 rc 各管一段（实测矩阵见 README）：
#   .bashrc 交互 bash ｜ .zshrc 交互 zsh ｜ .zshenv 所有 zsh（含 zsh -c）｜ .profile 登录 shell
for f in .bashrc .zshrc .zshenv .profile; do
    if [ "$ACTION" = set ]; then block_edit "$HOME/$f" "$(shell_block)" "$f"; else block_edit "$HOME/$f" "" "$f"; fi
done
git_apply; npm_apply; pip_apply
if [ "$ACTION" = set ]; then
    block_edit "$HOME/.curlrc" "$(curl_block)" ".curlrc"
    block_edit "$HOME/.wgetrc" "$(wget_block)" ".wgetrc"
else
    block_edit "$HOME/.curlrc" "" ".curlrc"
    block_edit "$HOME/.wgetrc" "" ".wgetrc"
fi
go_apply; etcenv_apply

say ""
if [ "$ACTION" = set ]; then
    p "自检" "bash $0 show"
    p "撤销" "bash $0 off$([ "$FLAG_ENV$FLAG_GO" = 00 ] && echo '' || echo '（带上用过的开关）')"
    say "  生效：交互 bash/zsh、bash -l、zsh -c/-lc、sh -l 已覆盖（rc 四个文件各管一段）"
    say "  没盖住：bash -c / bash 脚本（~/.bashrc 对非交互提前 return）→ 加 --env；cron 服务同理"
    say "  改完当前终端要先 source ~/.zshrc（或 ~/.bashrc）；已在运行的进程要重启才吃到"
fi