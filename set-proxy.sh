#!/usr/bin/env bash
# set-proxy.sh —— 把代理**写死进各工具自己的配置文件**，一次到位、不依赖任何 shell 函数/source/仓库。
#
#   ./set-proxy.sh tx          写 TX 代理（10.100.36.162:7890）
#   ./set-proxy.sh sh          写上海代理（10.10.2.14:7890）
#   ./set-proxy.sh http://x.y:1234   写自定义地址
#   ./set-proxy.sh off         全部撤掉（rc 块删除、git/npm/curl/wget/pip 各自 unset）
#   ./set-proxy.sh show        打印每一处当前生效值 + 端到端自检
#   ./set-proxy.sh --sweep     额外清掉 ~/.zshrc / ~/.bashrc 里残留的 `source ~/.sh-tx-proxy/proxy.sh`
#
# 可选开关（跟在动作后面）：
#   --apt        同时写 /etc/apt/apt.conf.d/95proxy（需要 root）
#   --goproxy    同时把 Go 模块换成国内镜像 GOPROXY=https://goproxy.cn,direct（走镜像就不必翻墙）
#
# 覆盖默认地址：环境变量 PROXY_SH / PROXY_TX / NO_PROXY_LIST
# 安全性：所有 rc 文件改动都被 BEGIN/END 标记包起来，重复执行只替换标记之间的内容；
#         首次改动留 <文件>.bak-set-proxy。off 能把标记块整个删干净（实测逐字节还原）。
# 幂等：可以反复跑。

set -uo pipefail

PROXY_SH="${PROXY_SH:-http://10.10.2.14:7890}"
PROXY_TX="${PROXY_TX:-http://10.100.36.162:7890}"
NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12}"

BEGIN='# ---- proxy (managed by set-proxy.sh) ----'
END='# ---- proxy end ----'
LEGACY='sh-tx-proxy/proxy.sh'

APT=0; GOPROXY_MIRROR=0; SWEEP=0; ACTION=""; URL=""

for a in "$@"; do
    case "$a" in
        --apt)        APT=1 ;;
        --goproxy)    GOPROXY_MIRROR=1 ;;
        --sweep)      SWEEP=1 ;;
        tx)           ACTION=set; URL="$PROXY_TX" ;;
        sh)           ACTION=set; URL="$PROXY_SH" ;;
        off|unset|rm) ACTION=off ;;
        show|status)  ACTION=show ;;
        http://*|https://*) ACTION=set; URL="$a" ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done
[ -n "$ACTION" ] || { echo "用法: $0 tx|sh|off|show|<url> [--apt] [--goproxy] [--sweep]" >&2; exit 2; }

# HOME 为空（某些 sudo/容器场景）会让下面的路径变成 /.bashrc，必须先拦住
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    [ -n "$HOME" ] || { echo "HOME 为空且查不到家目录，放弃。显式指定：HOME=/root bash $0 ..." >&2; exit 1; }
    echo "提示: HOME 未设置，按当前用户家目录 $HOME 处理" >&2
fi
[ -d "$HOME" ] || { echo "HOME=$HOME 不是目录，放弃。" >&2; exit 1; }
[ -w "$HOME" ] || { echo "HOME=$HOME 不可写，放弃（要不要 sudo -H？）" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
p()    { printf '%-22s %s\n' "$1" "$2"; }

# ---- rc 文件里写标记块（set）/ 删标记块（off）----------------------------------
rc_write() {
    local file="$1"
    [ -e "$file" ] || : > "$file" || { p "$(basename "$file")" "跳过：无法创建"; return; }
    [ -w "$file" ] || { p "$(basename "$file")" "跳过：不可写"; return; }
    [ -f "$file.bak-set-proxy" ] || cp -a "$file" "$file.bak-set-proxy"
    # 先把旧块删掉（标记行 + 到 END 之间），再追加新块到文件末尾
    awk -v b="$BEGIN" -v e="$END" 'index($0,b){inblk=1; next} inblk && index($0,e){inblk=0; next} inblk{next} {print}' "$file" > "$file.tmp-sp" || return
    if [ "$ACTION" = set ]; then
        # 文件末尾缺换行时补一个，避免拼行
        [ -s "$file.tmp-sp" ] && [ "$(tail -c1 "$file.tmp-sp" | wc -l)" -eq 0 ] && printf '\n' >> "$file.tmp-sp"
        {
            printf '%s\n' "$BEGIN"
            printf 'export http_proxy="%s"\n'  "$URL"
            printf 'export https_proxy="$http_proxy"\n'
            printf 'export all_proxy="$http_proxy"\n'
            printf 'export HTTP_PROXY="$http_proxy"\n'
            printf 'export HTTPS_PROXY="$http_proxy"\n'
            printf 'export ALL_PROXY="$http_proxy"\n'
            printf 'export no_proxy="%s"\n'    "$NO_PROXY_LIST"
            printf 'export NO_PROXY="$no_proxy"\n'
            printf '%s\n' "$END"
        } >> "$file.tmp-sp"
    fi
    mv "$file.tmp-sp" "$file" && p "$(basename "$file")" "$( [ "$ACTION" = set ] && echo "已写入 $URL" || echo "已删除代理块" )"
}

# ---- 清掉 sh-tx-proxy 的 source 残留 -----------------------------------------
rc_sweep() {
    local file="$1" n
    [ -f "$file" ] || return 0
    n=$(grep -c "$LEGACY" "$file" 2>/dev/null) || n=0
    [ "$n" -gt 0 ] || return 0
    [ -f "$file.bak-set-proxy" ] || cp -a "$file" "$file.bak-set-proxy"
    grep -v "$LEGACY" "$file" > "$file.tmp-sp" && mv "$file.tmp-sp" "$file"
    p "$(basename "$file")" "已移除 $n 行 proxy.sh 引用"
}

# ---- git ----------------------------------------------------------------------
git_apply() {
    have git || { p "git (~/.gitconfig)" "跳过：没装 git"; return; }
    if [ "$ACTION" = set ]; then
        git config --global http.proxy  "$URL"
        git config --global https.proxy "$URL"
    else
        git config --global --unset http.proxy   2>/dev/null
        git config --global --unset https.proxy  2>/dev/null
    fi
    local v; v=$(git config --global --get http.proxy 2>/dev/null)
    p "git (~/.gitconfig)" "${v:-未设置}"
}

# ---- npm ----------------------------------------------------------------------
npm_apply() {
    have npm || { p "npm (~/.npmrc)" "跳过：没装 npm"; return; }
    if [ "$ACTION" = set ]; then
        npm config set proxy "$URL" https-proxy "$URL" noproxy "$NO_PROXY_LIST" >/dev/null
    else
        npm config delete proxy >/dev/null 2>&1
        npm config delete https-proxy >/dev/null 2>&1
        npm config delete noproxy >/dev/null 2>&1
    fi
    p "npm (~/.npmrc)" "$( [ "$ACTION" = set ] && echo "$URL（npm 不读 http_proxy，必须写这里）" || echo "已清除（npm config get proxy → $(npm config get proxy 2>/dev/null)）" )"
}

# ---- curl / wget：写它们自己的 rc，标记块同款 ---------------------------------
oneline_rc() {   # $1=文件 生成内容函数用 ACTION/URL
    local file="$1"; shift
    [ -f "$file.bak-set-proxy" ] || { [ -e "$file" ] && cp -a "$file" "$file.bak-set-proxy"; }
    awk -v b="$BEGIN" -v e="$END" 'index($0,b){inblk=1; next} inblk && index($0,e){inblk=0; next} inblk{next} {print}' "$file" > "$file.tmp-sp" 2>/dev/null || : > "$file.tmp-sp"
    if [ "$ACTION" = set ]; then
        { printf '%s\n' "$BEGIN"; "$@"; printf '%s\n' "$END"; } >> "$file.tmp-sp"
    fi
    mv "$file.tmp-sp" "$file" && p "$(basename "$file")" "$( [ "$ACTION" = set ] && echo "已写入 $URL" || echo "已清除" )"
}

curl_apply() { oneline_rc "$HOME/.curlrc" sh -c 'echo "proxy = $0"; echo "noproxy = \"$1\"" ' "$URL" "$NO_PROXY_LIST"; }
wget_apply() { oneline_rc "$HOME/.wgetrc" sh -c 'echo "use_proxy=yes"; echo "http_proxy = $0"; echo "https_proxy = $0"; echo "no_proxy = \"$1\"" ' "$URL" "$NO_PROXY_LIST"; }

# ---- pip ----------------------------------------------------------------------
pip_apply() {
    have python3 || { p "pip (pip.conf)" "跳过：没装 python3"; return; }
    if [ "$ACTION" = set ]; then
        python3 -m pip config set global.proxy "$URL" >/dev/null 2>&1
        python3 -m pip config set global.noproxy "\"$NO_PROXY_LIST\"" >/dev/null 2>&1
    else
        python3 -m pip config unset global.proxy  >/dev/null 2>&1
        python3 -m pip config unset global.noproxy >/dev/null 2>&1
    fi
    p "pip (pip.conf)" "$( [ "$ACTION" = set ] && echo "$URL" || echo "已清除" )"
}

# ---- 可选项：apt / go ---------------------------------------------------------
apt_apply() {
    [ "$APT" = 1 ] || return 0
    local f=/etc/apt/apt.conf.d/95proxy
    if [ "$ACTION" = set ]; then
        if printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\nAcquire::no-proxy "%s";\n' "$URL" "$URL" "$NO_PROXY_LIST" > "$f" 2>/dev/null; then
            p "$f" "已写入（apt 走代理）"
        else
            p "$f" "跳过：需要 root（sudo $0 $ACTION --apt）"
        fi
    else
        rm -f "$f" 2>/dev/null && p "$f" "已删除" || p "$f" "跳过：需要 root"
    fi
}

go_apply() {
    [ "$GOPROXY_MIRROR" = 1 ] || return 0
    have go || { p "go (GOPROXY)" "跳过：没装 go"; return; }
    if [ "$ACTION" = set ]; then
        go env -w GOPROXY="https://goproxy.cn,direct" && p "go (GOPROXY)" "https://goproxy.cn,direct（国内镜像，不需要翻墙）"
    else
        go env -u GOPROXY 2>/dev/null; p "go (GOPROXY)" "$(go env GOPROXY)"
    fi
}

# ---- show / 自检 --------------------------------------------------------------
show_all() {
    say "== 每一处当前的代理配置 =="
    p "~/.bashrc 块"        "$(awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1} f && /http_proxy=/{print; exit}' "$HOME/.bashrc" 2>/dev/null | sed 's/export //')"
    p "~/.zshrc 块"         "$(awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1} f && /http_proxy=/{print; exit}' "$HOME/.zshrc" 2>/dev/null | sed 's/export //')"
    p "git http.proxy"      "$(git config --global --get http.proxy 2>/dev/null || echo 未设置)"
    p "npm proxy"           "$(npm config get proxy 2>/dev/null || echo 未设置)"
    p "curl ~/.curlrc"      "$(grep -m1 '^proxy' "$HOME/.curlrc" 2>/dev/null || echo 未设置)"
    p "wget ~/.wgetrc"      "$(grep -m1 'http_proxy' "$HOME/.wgetrc" 2>/dev/null || echo 未设置)"
    p "pip global.proxy"    "$(python3 -m pip config list 2>/dev/null | sed -n "s/^global.proxy='\(.*\)'.*/\1/p" | tr -d "\"" || echo 未设置)"
    p "go GOPROXY"          "$(go env GOPROXY 2>/dev/null || echo n/a)"
    p "当前 shell env"      "${https_proxy:-未设置}"
    p "sh-tx-proxy 残留"    "$(grep -l "$LEGACY" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null | tr '\n' ' ' || echo 无)"
    echo; say "== 端到端自检（走 ~/.curlrc，不吃当前 shell 变量，所以测的就是配置文件本身）=="
    for u in https://www.google.com https://github.com; do
        printf '  %-28s %s\n' "$u" "$(curl -sS -o /dev/null --config "$HOME/.curlrc" --connect-timeout 6 --max-time 12 -w '%{http_code} %{time_total}s' "$u" 2>&1 | tail -1)"
    done
    printf '  %-28s %s\n' "内网 http://10.100.4.43:3425" "$(curl -sS -o /dev/null --config "$HOME/.curlrc" --connect-timeout 4 --max-time 8 -w '%{http_code}（401=直连命中服务，没绕代理）' http://10.100.4.43:3425/v1/models 2>&1 | tail -1)"
}
say() { printf '%s\n' "$*"; }

# ---- 主流程 -------------------------------------------------------------------
if [ "$ACTION" = show ]; then show_all; exit 0; fi

[ "$SWEEP" = 1 ] && { say "== 清理 sh-tx-proxy 残留引用 =="; rc_sweep "$HOME/.bashrc"; rc_sweep "$HOME/.zshrc"; }

say "== $([ "$ACTION" = set ] && echo "写入代理 $URL" || echo '撤销所有代理配置') =="
rc_write "$HOME/.bashrc"
rc_write "$HOME/.zshrc"
rc_write "$HOME/.profile"
git_apply
npm_apply
curl_apply
wget_apply
pip_apply
apt_apply
go_apply

if [ "$ACTION" = set ]; then
    say ""
    p "生效方式" "新开终端 / 新起的进程自动带上；**当前这个终端先 source ~/.zshrc（或 source ~/.bashrc）**"
    p "自检" "bash set-proxy.sh show"
    p "撤销" "bash set-proxy.sh off"
    p "注意" "cron / systemd / bash -c 这类非交互会话不读 rc 文件，要显式带代理见 README 末节"
else
    say ""
    say "已撤销。注意：撤销后这台机器直连 google/github 会等超时（只有国内站通），不是配置坏了。"
fi
