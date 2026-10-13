# sh-tx-proxy/proxy.sh
# 代理手动切换：p-sh = 上海 10.10.2.14，p-tx = TX 10.100.36.162
# 命令实现为函数（不用 alias）：非交互 shell、脚本里 source 之后也能调用。
# git / npm 不用单独配：它们读的就是这里导出的环境变量（详见 README「git 和 npm 怎么跟着变」）。

PROXY_SH="http://10.10.2.14:7890"
PROXY_TX="http://10.100.36.162:7890"

NO_PROXY_LIST="localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12"

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
    echo "代理: $1"
    echo "shell / curl / wget / git / npm 在当前 shell 及其子进程内一起切换"
    _proxy_git_warn
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    unset no_proxy NO_PROXY
    unset npm_config_proxy npm_config_https_proxy npm_config_noproxy
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

    env | grep -iE '^(http|https|all|no)_proxy=' | sed 's/^/  env  /' | sort

    if command -v npm >/dev/null 2>&1; then
        echo "  npm  生效值: $(npm config get proxy 2>/dev/null || echo 未知)"
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
}

# 两地办公自检：哪个代理地址当前可达
proxy_test() {
    command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; return 1; }
    local _p _code
    for _p in "$PROXY_SH" "$PROXY_TX"; do
        _code=$(curl -sS -o /dev/null --connect-timeout 2 --max-time 3 -w '%{http_code}' "$_p" 2>/dev/null)
        if [ -n "$_code" ] && [ "$_code" != "000" ]; then
            echo "可达   $_p"
        else
            echo "不可达 $_p"
        fi
    done
}

p-sh()  { proxy_set "$PROXY_SH"; }
p-tx()  { proxy_set "$PROXY_TX"; }
poff()  { proxy_off; }
pst()   { proxy_status; }
ptest() { proxy_test; }
