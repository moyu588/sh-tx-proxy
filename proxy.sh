# sh-tx-proxy/proxy.sh
# 代理手动切换：p-sh = 上海 10.10.2.14，p-tx = TX 10.100.36.162
# 命令实现为函数（不用 alias）：非交互 shell、脚本里 source 之后也能调用。
# git / npm 不用单独配：它们读的就是这里导出的环境变量（详见 README「git 和 npm 怎么跟着变」）。
# 加载时默认会按本机网段自动选一个代理（PROXY_DEFAULT，见下），新开终端不用再手敲。

PROXY_SH="${PROXY_SH:-http://10.10.2.14:7890}"
PROXY_TX="${PROXY_TX:-http://10.100.36.162:7890}"

NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12}"

# 自动选路（source 本脚本时执行一次）：
#   auto（默认）—— 按本机 IPv4 段判断人在哪：10.100.* → TX，10.10.* → 上海；认不出来就不设
#   sh / tx     —— 固定用某一边，不看网段
#   off         —— 关掉自动，回到纯手动（以前就是这个行为）
# 用法：在启动文件里 source 之前 export PROXY_DEFAULT=tx，或者临时 PROXY_DEFAULT=off bash -c '...'
PROXY_DEFAULT="${PROXY_DEFAULT:-auto}"

# 自动设上时不打字（每开一个终端都刷一行太吵），想看过程就 PROXY_DEFAULT_VERBOSE=1
PROXY_DEFAULT_VERBOSE="${PROXY_DEFAULT_VERBOSE:-0}"

# 只用于 pst 显示来源，不导出
PROXY_APPLIED_BY=""

# 导出两套约定：
#   http_proxy/https_proxy/all_proxy/no_proxy —— curl、wget、git、Go、pip 等认这套
#   npm_config_proxy / npm_config_https_proxy / npm_config_noproxy —— npm 7+ 只认这套
#   （npm 不读 http_proxy，且这几个 env 的优先级高于 ~/.npmrc，所以 .npmrc 不用改）
_proxy_export() {
    local _p="$1"
    export http_proxy="$_p" https_proxy="$_p" HTTP_PROXY="$_p" HTTPS_PROXY="$_p"
    export all_proxy="$_p" ALL_PROXY="$_p"
    export no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST"
    export npm_config_proxy="$_p" npm_config_https_proxy="$_p"
    export npm_config_noproxy="$NO_PROXY_LIST"
}

# 本机所有非回环 IPv4（判断人在哪个办公网段用）
_proxy_local_ips() {
    local _ips=""
    if command -v hostname >/dev/null 2>&1; then
        _ips=$(hostname -I 2>/dev/null)
    fi
    if [ -z "$_ips" ] && command -v ip >/dev/null 2>&1; then
        _ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); printf "%s ", $4}')
    fi
    if [ -z "$_ips" ] && command -v ifconfig >/dev/null 2>&1; then
        _ips=$(ifconfig 2>/dev/null | awk '{if (match($0,/inet (addr:)?[0-9.]+/)) {s=substr($0,RSTART,RLENGTH); gsub(/.*inet (addr:)?/,"",s); printf "%s ", s}}')
    fi
    echo "${_ips:-unknown}"
}

# 主地址，只给 pst / 提示文案显示用
_proxy_local_ip() {
    echo "$(_proxy_local_ips)" | tr -s ' \n' ' ' | cut -d' ' -f1
}

# 按 PROXY_DEFAULT 得出该用哪个代理：echo sh / tx / 空（空=不设）
# 多网卡 / VPN 时按下面 case 的书写顺序优先，更具体的段写前面（10.100 必须早于 10.10）
_proxy_pick() {
    case "$PROXY_DEFAULT" in
        sh|tx) echo "$PROXY_DEFAULT"; return 0 ;;
        auto)  ;;
        *)     return 0 ;;          # off / 空 / 不认识的值：一律不自动设
    esac
    local _ips
    _ips=" $(echo "$(_proxy_local_ips)" | tr -s ' \n' ' ') "
    case "$_ips" in
        *" 10.100."*) echo tx ;;    # TX 网段（10.100.0.0/16）
        *" 10.10."*)  echo sh ;;    # 上海网段（10.10.0.0/16）
        *)            return 0 ;;
    esac
}

# source 本脚本时跑一次：环境里已经有代理就什么都不动（继承的、手动 export 的都优先）
_proxy_autoset() {
    if [ -n "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}" ]; then
        PROXY_APPLIED_BY="继承自环境（脚本未改动）"
        return 0
    fi
    local _pick _url
    _pick=$(_proxy_pick)
    [ -z "$_pick" ] && return 0
    case "$_pick" in
        sh) _url="$PROXY_SH" ;;
        tx) _url="$PROXY_TX" ;;
    esac
    _proxy_export "$_url"
    PROXY_APPLIED_BY="自动选路 PROXY_DEFAULT=$PROXY_DEFAULT（本机 $(_proxy_local_ip) → $_pick）"
    [ "$PROXY_DEFAULT_VERBOSE" = "1" ] && echo "proxy.sh: 已自动设 $_url  ← $PROXY_APPLIED_BY" >&2
    return 0
}

# git 配置里若写死了 proxy，优先级高于环境变量，切换就不会对 git 生效 —— 直接指出来
_proxy_git_warn() {
    command -v git >/dev/null 2>&1 || return 0
    local _stale
    _stale=$(git config --list --show-origin 2>/dev/null | grep -iE '\.proxy=')
    [ -z "$_stale" ] && return 0
    echo "警告: git 配置写死了代理，会盖掉环境变量，git 不会跟随 p-sh/p-tx:" >&2
    echo "$_stale" | sed 's/^/  /' >&2
    echo "一次性清理: git config --global --unset http.proxy; git config --global --unset https.proxy" >&2
    echo "（若是 remote.<name>.proxy 或 http.<url>.proxy，按 --show-origin 给出的 key 单独 unset）" >&2
}

proxy_set() {
    if [ -z "$1" ]; then
        echo "用法: proxy_set http://10.10.2.14:7890" >&2
        return 2
    fi
    _proxy_export "$1"
    PROXY_APPLIED_BY="手动设置"
    echo "代理: $1"
    echo "shell / curl / wget / git / npm 在当前 shell 及其子进程内一起切换"
    _proxy_git_warn
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    unset no_proxy NO_PROXY
    unset npm_config_proxy npm_config_https_proxy npm_config_noproxy
    PROXY_APPLIED_BY="poff 手动关闭"
    echo "代理已关闭"
    _proxy_git_warn
}

proxy_status() {
    local _cur="${https_proxy:-${HTTPS_PROXY:-}}"
    if [ -n "$_cur" ]; then
        case "$_cur" in
            "$PROXY_SH") echo "当前: 上海  $_cur" ;;
            "$PROXY_TX") echo "当前: TX    $_cur" ;;
            *) echo "当前: 自定义 $_cur" ;;
        esac
    else
        echo "当前: 未设置代理"
    fi
    [ -n "$PROXY_APPLIED_BY" ] && echo "  来源  $PROXY_APPLIED_BY"

    env | grep -iE '^(http|https|all|no)_proxy=' | sed 's/^/  env  /' | sort

    # 自动选路的判定结果单独打一行，方便排查「为什么这台开了终端没代理」
    local _pick _ip
    _ip=$(_proxy_local_ip); _pick=$(_proxy_pick)
    echo "  自动  本机 $_ip / PROXY_DEFAULT=${PROXY_DEFAULT:-未设置} → $( [ -n "$_pick" ] && echo "$_pick（$( [ "$_pick" = sh ] && echo "$PROXY_SH" || echo "$PROXY_TX" )）" || echo "不自动设" )"

    if command -v npm >/dev/null 2>&1; then
        local _np
        _np=$(npm config get proxy 2>/dev/null)
        case "$_np" in
            null|undefined|"") _np="未设置（npm 不读 http_proxy，靠 npm_config_proxy）" ;;
        esac
        echo "  npm  生效值: $_np"
    else
        echo "  npm  生效值: ${npm_config_proxy:-（未设置，未装 npm）}"
    fi

    if command -v git >/dev/null 2>&1; then
        local _gc
        _gc=$(git config --list --show-origin 2>/dev/null | grep -iE '\.proxy=' | tr '\n' ' ')
        if [ -n "$_gc" ]; then
            echo "  git  生效值: 被 git 配置写死 -> ${_gc% }"
        else
            echo "  git  生效值: ${_cur:-直连}（跟随环境变量）"
        fi
    fi

    # 没有这行说明当前 shell 根本没 source 过本脚本（bash / cron / systemd 常见）
    type p-sh >/dev/null 2>&1 || echo "  提示: 这个 shell 里没有 p-sh 函数，启动文件可能没 source proxy.sh"
}

# 两地办公自检：哪个代理地址当前可达
proxy_test() {
    command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; return 1; }
    local _p _code
    for _p in "$PROXY_SH" "$PROXY_TX"; do
        # --noproxy 关键：否则当前已设的代理会替另一个地址「代答」，两地互测全是假阳性
        _code=$(curl -sS -o /dev/null --noproxy '*' --connect-timeout 2 --max-time 3 -w '%{http_code}' "$_p" 2>/dev/null)
        if [ -n "$_code" ] && [ "$_code" != "000" ]; then
            echo "可达   $_p"
        else
            echo "不可达 $_p"
        fi
    done
}

# 加载即生效：新开终端不用再手敲 p-sh / p-tx（PROXY_DEFAULT=off 可关掉）
# 必须放在带连字符的命令名之前：dash/sh 解析到 `p-sh()` 会 Bad function name 直接中断，
# 自动选路写在后面的话 POSIX shell 里就永远跑不到。
_proxy_autoset

poff()  { proxy_off; }
pst()   { proxy_status; }
ptest() { proxy_test; }

# 连字符函数名只有 bash / zsh 接受，dash 里要当字符串 eval，否则整个文件解析失败
if [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
    eval 'p-sh()  { proxy_set "$PROXY_SH"; }'
    eval 'p-tx()  { proxy_set "$PROXY_TX"; }'
fi
