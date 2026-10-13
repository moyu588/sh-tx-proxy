# sh-tx-proxy/proxy.sh
# 代理手动切换：p-sh = 10.10.2.14，p-tx = 10.100.36.162

PROXY_SH="http://10.10.2.14:7890"
PROXY_TX="http://10.100.36.162:7890"

NO_PROXY_LIST="localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12"

proxy_set() {
    export http_proxy="$1" https_proxy="$1" HTTP_PROXY="$1" HTTPS_PROXY="$1" \
           all_proxy="$1" ALL_PROXY="$1" \
           no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST"
    echo "代理: $1"
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    echo "代理已关闭"
}

proxy_status() {
    env | grep -iE '^(http|https|all|no)_proxy=' | sort || echo "未设置代理"
}

alias p-sh='proxy_set "$PROXY_SH"'
alias p-tx='proxy_set "$PROXY_TX"'
alias poff='proxy_off'
alias pst='proxy_status'