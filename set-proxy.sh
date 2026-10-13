#!/usr/bin/env bash
# set-proxy.sh —— 把代理**写死进各工具自己的配置文件 + 系统级环境变量**，之后不依赖任何 source/函数/仓库。
#
#   ./set-proxy.sh tx              写 TX 代理（10.100.36.162:7890）
#   ./set-proxy.sh sh              写上海代理（10.10.2.14:7890）
#   ./set-proxy.sh http://x:1234   写自定义地址
#   ./set-proxy.sh off             全部撤销（实测 rc 文件逐字节还原；撤销也要带上同样的开关）
#   ./set-proxy.sh show            打印每一处当前值 + 端到端自检
#   ./set-proxy.sh --sweep         附带清掉 rc 里残留的 `source ~/.sh-tx-proxy/proxy.sh`
#
# 覆盖范围与开关：
#   默认（无需开关）：shell 四个 rc —— ~/.bashrc(交互 bash) ~/.zshrc(交互 zsh)
#                     ~/.zshenv(所有 zsh，含 zsh -c 脚本) ~/.profile(bash -l / sh -l / su - 登录)
#                     工具配置文件 —— git ~/.gitconfig ｜ npm ~/.npmrc ｜ curl ~/.curlrc
#                     ｜ wget ~/.wgetrc ｜ pip ~/.config/pip/pip.conf
#   --env        /etc/environment                      → python/requests、Go 程序、cron 这类**只读环境变量**的
#   --systemd    /etc/systemd/system.conf.d/99-set-proxy.conf → 所有 systemd 服务（需 daemon-reexec/重启）
#   --docker     ~/.docker/config.json 的 proxies      → docker run / build 容器里的程序
#   --go         go env -w GOPROXY=国内镜像            → Go 模块下载（写配置文件，不需要环境变量）
#   --gem        ~/.gemrc 的 :proxy:                   → RubyGems
#   --apt        /etc/apt/apt.conf.d/95proxy           → apt（需 root）
#   --everything 上面全要
#
# rc 文件盖不住的：`bash -c` / bash 脚本（Kali 的 ~/.bashrc 第 6-8 行对非交互直接 return，
# 追加在末尾的块永远读不到；BASH_ENV 指向 .bashrc 也会被同一个 return 挡住）→ 用 --env。
#
# 默认地址可用环境变量覆盖：PROXY_SH / PROXY_TX / NO_PROXY_LIST / GOPROXY_MIRROR
# 演练（不碰真系统）：SET_PROXY_HOME=/tmp/h SET_PROXY_ETC_DIR=/tmp/e bash set-proxy.sh tx --everything
# 安全性：所有写入都被包在 `# ---- proxy (managed by set-proxy.sh) ----` … `# ---- proxy end ----` 之间，
#         重复执行只替换该块不堆叠；首次改动留 <文件>.bak-set-proxy；HOME 空/不可写直接拒绝执行。

set -uo pipefail

PROXY_SH="${PROXY_SH:-http://10.10.2.14:7890}"
PROXY_TX="${PROXY_TX:-http://10.100.36.162:7890}"
NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12}"
GOPROXY_MIRROR="${GOPROXY_MIRROR:-https://goproxy.cn,direct}"

BEGIN='# ---- proxy (managed by set-proxy.sh) ----'
END='# ---- proxy end ----'
LEGACY='sh-tx-proxy/proxy.sh'
ETC_DIR="${SET_PROXY_ETC_DIR:-/etc}"

FLAG_ENV=0; FLAG_SYSTEMD=0; FLAG_DOCKER=0; FLAG_GO=0; FLAG_GEM=0; FLAG_APT=0
SWEEP=0; ACTION=""; URL=""

for a in "$@"; do
    case "$a" in
        --env)        FLAG_ENV=1 ;;
        --systemd)    FLAG_SYSTEMD=1 ;;
        --docker)     FLAG_DOCKER=1 ;;
        --go)         FLAG_GO=1 ;;
        --gem)        FLAG_GEM=1 ;;
        --apt)        FLAG_APT=1 ;;
        --everything) FLAG_ENV=1; FLAG_SYSTEMD=1; FLAG_DOCKER=1; FLAG_GO=1; FLAG_GEM=1; FLAG_APT=1 ;;
        --sweep)      SWEEP=1 ;;
        tx)           ACTION=set; URL="$PROXY_TX" ;;
        sh)           ACTION=set; URL="$PROXY_SH" ;;
        off|unset|rm) ACTION=off ;;
        show|status)  ACTION=show ;;
        http://*|https://*) ACTION=set; URL="$a" ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done
[ -n "$ACTION" ] || { echo "用法: $0 tx|sh|off|show|<url> [--env --systemd --docker --go --gem --apt | --everything] [--sweep]" >&2; exit 2; }

if [ -n "${SET_PROXY_HOME:-}" ]; then HOME="$SET_PROXY_HOME"; fi
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    [ -n "$HOME" ] || { echo "HOME 为空且查不到家目录，放弃。可显式：HOME=/root bash $0 ..." >&2; exit 1; }
fi
[ -d "$HOME" ] || { echo "HOME=$HOME 不是目录，放弃。" >&2; exit 1; }
if [ "$ACTION" != show ] && [ ! -w "$HOME" ]; then echo "HOME=$HOME 不可写，放弃（要不要 sudo -H？）" >&2; exit 1; fi

have() { command -v "$1" >/dev/null 2>&1; }
# 按「显示宽度」对齐：中文算 2 列，wc -L 正好给的是显示宽度
p()    { local w; w=$(printf '%s' "$1" | wc -L); printf '%s%*s %s\n' "$1" "$(( 24 > w ? 24 - w : 1 ))" '' "$2"; }
say()  { printf '%s\n' "$*"; }
lbl()  { basename "$1"; }

# ---- 通用：在文件里替换/删除标记块 -------------------------------------------
block_edit() {   # $1=文件  $2=set 时要写的多行内容  $3=显示标签
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
    # off 之后如果文件被清成空的（.zshenv 这类原本不存在的），连文件和备份一起删掉，
    # 做到「原本没有的文件，撤销后也不留 0 字节空壳」。
    if [ "$ACTION" != set ] && [ ! -s "$file" ]; then
        rm -f "$file" "$file.bak-set-proxy"
        p "$label" "已清除（原本无此文件，空壳一并删除）"
        return 0
    fi
    p "$label" "$( [ "$ACTION" = set ] && echo "$URL" || echo "已清除" )"
}

# ---- 块内容生成 --------------------------------------------------------------
shell_block() {
    printf 'export http_proxy="%s"\nexport https_proxy="$http_proxy"\nexport all_proxy="$http_proxy"\n' "$URL"
    printf 'export HTTP_PROXY="$http_proxy"\nexport HTTPS_PROXY="$http_proxy"\nexport ALL_PROXY="$http_proxy"\n'
    printf 'export no_proxy="%s"\nexport NO_PROXY="$no_proxy"\n' "$NO_PROXY_LIST"
}
# /etc/environment 由 pam_env 解析，不做变量展开 → 必须全字面值
env_block() {
    printf 'http_proxy=%s\nhttps_proxy=%s\nall_proxy=%s\n' "$URL" "$URL" "$URL"
    printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nALL_PROXY=%s\n' "$URL" "$URL" "$URL"
    printf 'no_proxy=%s\nNO_PROXY=%s\n' "$NO_PROXY_LIST" "$NO_PROXY_LIST"
}
gem_block() { printf ':proxy: %s\n:http_proxy: %s\n:https_proxy: %s\n:no_proxy: %s\n' "$URL" "$URL" "$URL" "$NO_PROXY_LIST"; }
curl_block() { printf 'proxy = %s\nnoproxy = "%s"\n' "$URL" "$NO_PROXY_LIST"; }
wget_block() { printf 'use_proxy=yes\nhttp_proxy = %s\nhttps_proxy = %s\nno_proxy = "%s"\n' "$URL" "$URL" "$NO_PROXY_LIST"; }
apt_block()  { printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\nAcquire::no-proxy "%s";\n' "$URL" "$URL" "$NO_PROXY_LIST"; }

rc_sweep() {
    local file="$1" n
    [ -f "$file" ] || return 0
    n=$(grep -c "$LEGACY" "$file" 2>/dev/null); n=${n:-0}
    [ "$n" -gt 0 ] || return 0
    [ -f "$file.bak-set-proxy" ] || cp -a "$file" "$file.bak-set-proxy"
    grep -v "$LEGACY" "$file" > "$file.tmp-set-proxy" && mv "$file.tmp-set-proxy" "$file"
    p "$(lbl "$file")" "已移除 $n 行 proxy.sh 引用"
}

# ---- 各工具 ------------------------------------------------------------------
git_apply() {
    have git || { p "git (~/.gitconfig)" "跳过：没装 git"; return; }
    if [ "$ACTION" = set ]; then git config --global http.proxy "$URL"; git config --global https.proxy "$URL"
    else git config --global --unset http.proxy 2>/dev/null; git config --global --unset https.proxy 2>/dev/null; fi
    p "git (~/.gitconfig)" "$(git config --global --get http.proxy 2>/dev/null || echo 未设置)"
}
npm_apply() {
    have npm || { p "npm (~/.npmrc)" "跳过：没装 npm"; return; }
    if [ "$ACTION" = set ]; then npm config set proxy "$URL" https-proxy "$URL" noproxy "$NO_PROXY_LIST" >/dev/null 2>&1
    else npm config delete proxy >/dev/null 2>&1; npm config delete https-proxy >/dev/null 2>&1; npm config delete noproxy >/dev/null 2>&1; fi
    p "npm (~/.npmrc)" "$( [ "$ACTION" = set ] && echo "$URL（npm 不读 http_proxy）" || echo "已清除 → $(npm config get proxy 2>/dev/null)" )"
}
pip_apply() {
    have python3 || { p "pip (pip.conf)" "跳过：没装 python3"; return; }
    if [ "$ACTION" = set ]; then
        python3 -m pip config set global.proxy "$URL" >/dev/null 2>&1
        python3 -m pip config set global.noproxy "\"$NO_PROXY_LIST\"" >/dev/null 2>&1
    else
        python3 -m pip config unset global.proxy >/dev/null 2>&1
        python3 -m pip config unset global.noproxy >/dev/null 2>&1
        # pip 撤完会留个空文件（或只剩一个 [global] 头）；这种壳删掉，别留垃圾
        local pc="$HOME/.config/pip/pip.conf"
        if [ -f "$pc" ]; then
            if [ ! -s "$pc" ] || ! grep -qE '^[[:space:]]*[a-z]' "$pc"; then rm -f "$pc"; rmdir "$HOME/.config/pip" 2>/dev/null; fi
        fi
    fi
    p "pip (pip.conf)" "$( [ "$ACTION" = set ] && echo "$URL" || echo "已清除" )"
}
docker_apply() {
    [ "$FLAG_DOCKER" = 1 ] || return 0
    local f="$HOME/.docker/config.json"
    if [ "$ACTION" = set ]; then
        mkdir -p "$HOME/.docker" 2>/dev/null || { p "docker (config.json)" "跳过：建不了 ~/.docker"; return; }
        python3 - "$f" "$URL" "$NO_PROXY_LIST" <<'PY'
import json, os, sys
f, url, noproxy = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
if os.path.exists(f):
    try:
        with open(f) as fh: cfg = json.load(fh)
    except Exception:
        cfg = {}
cfg["proxies"] = {"default": {"httpProxy": url, "httpsProxy": url, "noProxy": noproxy}}
with open(f, "w") as fh:
    json.dump(cfg, fh, indent=2)
PY
        p "docker (~/.docker/config.json)" "proxies.default = $URL"
        have docker || say "  ↳ 本机当前没装 docker：这条是预埋，装上后 docker run / build 容器内自动带代理"
        say "  ↳ 守护进程自己拉镜像不吃这个文件，得单独给 docker.service 加 Environment=\"HTTPS_PROXY=$URL\""
    else
        if [ -f "$f" ]; then
            python3 - "$f" <<'PY' 2>/dev/null
import json, os, sys
f = sys.argv[1]
with open(f) as fh: cfg = json.load(fh)
cfg.pop("proxies", None)
if cfg:
    with open(f, "w") as fh: json.dump(cfg, fh, indent=2)
else:                      # 撤完啥都不剩（这个文件当初就是为代理建的）→ 删掉，不留 {}
    os.remove(f)
PY
        fi
        p "docker (~/.docker/config.json)" "已清除 proxies"
        rmdir "$HOME/.docker" 2>/dev/null   # 只清理空目录；里面还有别的东西就留着
    fi
}
go_apply() {
    [ "$FLAG_GO" = 1 ] || return 0
    have go || { p "go (go env)" "跳过：没装 go"; return; }
    if [ "$ACTION" = set ]; then
        go env -w GOPROXY="$GOPROXY_MIRROR" && p "go (go env)" "GOPROXY=$GOPROXY_MIRROR（写进 ~/.config/go/env，不吃环境变量）"
        say "  ↳ Go 编译出来的程序自己发请求仍读环境变量 → 配合 --env / --systemd"
    else
        go env -u GOPROXY >/dev/null 2>&1
        # go env -u 会把文件留空壳；空文件删掉，回到「没配置过」的状态
        local genv; genv="$(go env GOENV 2>/dev/null)"
        [ -n "$genv" ] && [ -f "$genv" ] && [ ! -s "$genv" ] && rm -f "$genv"
        p "go (go env)" "$(go env GOPROXY)"
    fi
}
gem_apply() {
    [ "$FLAG_GEM" = 1 ] || return 0
    have ruby || have gem || { p "gem (~/.gemrc)" "跳过：没装 ruby/gem"; return; }
    block_edit "$HOME/.gemrc" "$(gem_block)" "gem (~/.gemrc)"
}
apt_apply() {
    [ "$FLAG_APT" = 1 ] || return 0
    local f="$ETC_DIR/apt.conf.d/95proxy"
    if [ "$ACTION" = set ]; then
        mkdir -p "$ETC_DIR/apt.conf.d" 2>/dev/null
        block_edit "$f" "$(apt_block)" "/etc/apt/apt.conf.d/95proxy"
    else
        if rm -f "$f" "$f.bak-set-proxy" 2>/dev/null; then
            rmdir "$ETC_DIR/apt.conf.d" 2>/dev/null
            p "/etc/apt/apt.conf.d/95proxy" "已删除（含备份）"
        else
            p "/etc/apt/apt.conf.d/95proxy" "跳过：需要 root"
        fi
    fi
}
etcenv_apply() {
    [ "$FLAG_ENV" = 1 ] || return 0
    block_edit "$ETC_DIR/environment" "$(env_block)" "/etc/environment"
    [ "$ACTION" = set ] && say "  ↳ 生效范围：之后新登录的会话（sshd/login/su/cron 的 PAM 栈里都有 pam_env，实测确认）。已跑的进程要重启才吃到"
}
systemd_apply() {
    [ "$FLAG_SYSTEMD" = 1 ] || return 0
    local d="$ETC_DIR/systemd/system.conf.d"
    local f="$d/99-set-proxy.conf"
    if [ "$ACTION" = set ]; then
        mkdir -p "$d" 2>/dev/null
        { printf '# 由 set-proxy.sh 生成\n[Manager]\n'
          printf 'DefaultEnvironment="http_proxy=%s" "https_proxy=%s" "all_proxy=%s"\n' "$URL" "$URL" "$URL"
          printf 'DefaultEnvironment="HTTP_PROXY=%s" "HTTPS_PROXY=%s" "ALL_PROXY=%s"\n' "$URL" "$URL" "$URL"
          printf 'DefaultEnvironment="no_proxy=%s" "NO_PROXY=%s"\n' "$NO_PROXY_LIST" "$NO_PROXY_LIST"; } > "$f" 2>/dev/null \
            && p "/etc/systemd/system.conf.d/99-set-proxy.conf" "已写入（所有系统服务）" \
            || p "/etc/systemd/system.conf.d/99-set-proxy.conf" "跳过：需要 root"
        say "  ↳ 生效要 systemctl daemon-reexec（或重启）；只想给个别服务就别用这开关，改 unit 的 Environment="
    else
        rm -f "$f" 2>/dev/null && p "/etc/systemd/system.conf.d/99-set-proxy.conf" "已删除"
    fi
}

# ---- show --------------------------------------------------------------------
head_of_block() { [ -f "$1" ] && awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1;next} index($0,e){f=0} f && /proxy/{print;exit}' "$1" | head -1; }
bv() {  # $1=文件 $2=可选匹配模式
    local pat="${2:-proxy}" v
    v="$( [ -f "$1" ] && awk -v b="$BEGIN" -v e="$END" -v p="$pat" 'index($0,b){f=1;next} index($0,e){f=0} f && index($0,p){print;exit}' "$1" | head -1 )"
    [ -n "$v" ] && printf '%s' "$v" || printf '未配置'
}
show_all() {
    say "== 每一处当前配置 =="
    p "shell rc 块"      "$(for f in .bashrc .zshrc .zshenv .profile; do [ -f "$HOME/$f" ] && grep -qF "$BEGIN" "$HOME/$f" 2>/dev/null && printf '%s ' "$f"; done)"
    p "shell rc 值"      "$(grep -h -m1 'export http_proxy' "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.profile" 2>/dev/null | head -1 | sed 's/^export //')"
    p "git"              "$(git config --global --get http.proxy 2>/dev/null || echo 未配置)"
    p "npm"              "$(npm config get proxy 2>/dev/null || echo 未配置)"
    p "curl"             "$(bv "$HOME/.curlrc")"
    p "wget"             "$(bv "$HOME/.wgetrc")"
    p "pip"              "$(python3 -m pip config list 2>/dev/null | sed -n "s/^global.proxy='\\(.*\\)'.*/\\1/p" | tr -d '\"')"
    p "docker"           "$( [ -f "$HOME/.docker/config.json" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("proxies",{}).get("default",{}).get("httpsProxy","未配置"))' "$HOME/.docker/config.json" 2>/dev/null || echo 未配置)"
    p "go GOPROXY"       "$(go env GOPROXY 2>/dev/null || echo n/a)"
    p "gem"              "$(bv "$HOME/.gemrc")"
    p "/etc/environment" "$(bv "$ETC_DIR/environment")"
    p "systemd 全局"     "$( [ -f "$ETC_DIR/systemd/system.conf.d/99-set-proxy.conf" ] && grep -m1 -o 'https_proxy=[^"]*' "$ETC_DIR/systemd/system.conf.d/99-set-proxy.conf" || echo 未配置)"
    p "apt 95proxy"      "$(bv "$ETC_DIR/apt.conf.d/95proxy" 'Acquire::http')"
    p "当前会话 env"     "${https_proxy:-未设置}"
    local res; res="$(grep -l "$LEGACY" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.profile" 2>/dev/null | tr '\n' ' ')"
    p "旧 proxy.sh 残留" "${res:-无}"

    echo; say "== 端到端自检 =="
    printf '  %-22s %s\n' "curl（读 ~/.curlrc）" "$(curl -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_total}s' https://github.com 2>&1 | tail -1)"
    # python 只认环境变量：有 --env 块就照登录会话那样注入再测，没有就明说为啥跳过
    local penv=""
    [ -f "$ETC_DIR/environment" ] && penv="$(sed -n "/$BEGIN/,/$END/p" "$ETC_DIR/environment" 2>/dev/null | grep -v '^#' | tr '\n' ' ')"
    if [ -n "$penv" ]; then
        printf '  %-22s %s\n' "python（注入 --env）" "$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY $penv python3 -c 'import requests;print(requests.get("https://www.google.com",timeout=10).status_code)' 2>&1 | tail -1 | cut -c1-40)"
    else
        printf '  %-22s %s\n' "python requests" "跳过：它只认环境变量，配 --env 后再看（也可显式 export 后手动测）"
    fi
    local gremote; gremote="$(timeout 20 git ls-remote https://github.com/moyu588/sh-tx-proxy.git HEAD 2>&1 | cut -c1-40)"
    printf '  %-22s %s\n' "git ls-remote"      "${gremote:-失败/超时（无代理时属正常）}"
    printf '  %-22s %s\n' "内网(应直连)"        "$(curl -sS -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code}' http://10.100.4.43:3425/v1/models 2>&1 | tail -1)"
}

# ---- 主流程 ------------------------------------------------------------------
if [ "$ACTION" = show ]; then show_all; exit 0; fi
say "== $([ "$ACTION" = set ] && echo "写入 $URL" || echo '撤销所有代理配置') =="
if [ "$SWEEP" = 1 ]; then say "-- 清理 sh-tx-proxy 残留引用 --"; for f in .bashrc .zshrc .zshenv .zprofile .profile; do rc_sweep "$HOME/$f"; done; fi

# 四个 rc 各管一段，缺一不可（实测矩阵见 README）：
#   .bashrc  交互 bash        .zshrc   交互 zsh
#   .zshenv  **所有** zsh（含 zsh -c / zsh -lc 这类非交互，少了它脚本里的 zsh 就没代理）
#   .profile 登录 shell（bash -l / sh -l / su -；bash 没 .bash_profile 时读这个）
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
docker_apply; go_apply; gem_apply; apt_apply; etcenv_apply; systemd_apply

say ""
if [ "$ACTION" = set ]; then
    p "自检" "bash $0 show"
    p "撤销" "bash $0 off   # 记得带上这次用过的同样开关"
    say "  生效：交互 bash/zsh、bash -l、zsh -c/-lc、sh -l 已覆盖（rc 四个文件各管一段）"
    say "  没盖住：bash -c / bash 脚本（.bashrc 对非交互提前 return）→ 加 --env；cron/systemd 服务 → --env / --systemd"
    say "  改完当前终端要先 source ~/.zshrc（或 ~/.bashrc）；已在运行的进程/服务要重启才吃到新配置"
fi
