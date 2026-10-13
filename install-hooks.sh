#!/usr/bin/env bash
# sh-tx-proxy/install-hooks.sh
# 目的：让「新开任何东西都自动带代理」，不用再手敲 p-sh / p-tx。
# proxy.sh 自带按网段自动选路（PROXY_DEFAULT=auto），本脚本只负责把它挂到各类会话的入口上。
#
#   ./install-hooks.sh              只挂当前用户（~/.bashrc、~/.zshrc）—— 交互终端够用
#   ./install-hooks.sh --system     再挂系统级（/etc/profile.d、/etc/zsh/zshenv、/etc/environment）
#   ./install-hooks.sh --all        = 用户级 + 系统级（需 root）
#   ./install-hooks.sh --check      跑覆盖矩阵自检，不改文件
#   ./install-hooks.sh --uninstall  撤销本脚本加的行（按标记删，不碰其它内容）
#
# 可测性：PROXY_HOOKS_HOME / PROXY_HOOKS_ETC 可把写入目标改到别处（自检/演练用）。

set -uo pipefail

MARKER='# sh-tx-proxy hook (managed by install-hooks.sh)'
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_HOME="${PROXY_HOOKS_HOME:-$HOME}"
HOOKS_ETC="${PROXY_HOOKS_ETC:-/etc}"
SRC_LINE="source \"$REPO/proxy.sh\""

USER_MODE=0; SYSTEM_MODE=0; CHECK_ONLY=0; UNINSTALL=0
for a in "$@"; do
    case "$a" in
        --system)   SYSTEM_MODE=1 ;;
        --all)      USER_MODE=1; SYSTEM_MODE=1 ;;
        --check)    CHECK_ONLY=1 ;;
        --uninstall)UNINSTALL=1 ;;
        -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数: $a（--system/--all/--check/--uninstall）" >&2; exit 2 ;;
    esac
done
[ "$USER_MODE" = 1 ] || [ "$SYSTEM_MODE" = 1 ] || [ "$CHECK_ONLY" = 1 ] || [ "$UNINSTALL" = 1 ] || USER_MODE=1

say()  { printf '%s\n' "$*"; }
skip() { printf '  跳过  %s（%s）\n' "$1" "$2"; }

# 追加一行（幂等：已有同名 source 行就不重复加）
append_once() {
    local file="$1" line="$2"
    [ -e "$file" ] || : > "$file" || { skip "$file" "无法创建"; return 1; }
    [ -w "$file" ] || { skip "$file" "不可写（要 root？）"; return 1; }
    # 已经挂过就不重复加：带标记的，或者手工写过 source .../proxy.sh 的
    if grep -qF "$MARKER" "$file" 2>/dev/null || grep -q 'sh-tx-proxy/proxy.sh' "$file" 2>/dev/null; then
        skip "$file" "已挂过（不重复追加）"; return 0
    fi
    cp -a "$file" "$file.bak-sh-tx-proxy" 2>/dev/null
    # 只在文件末尾缺换行时补一个：这样卸载删掉那两行就能逐字节还原
    [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" -eq 0 ] && printf '\n' >> "$file"
    printf '%s\n%s\n' "$MARKER" "$line" >> "$file" && say "  写入  $file  ← source proxy.sh"
}

# 演练环境里补上 ~/.sh-tx-proxy 软链，否则钩子里 `~` 形式的路径解析不到，check 会假阴性
ensure_symlink() {
    [ -e "$HOOKS_HOME/.sh-tx-proxy" ] && return 0
    ln -s "$REPO" "$HOOKS_HOME/.sh-tx-proxy" 2>/dev/null && say "  建链  $HOOKS_HOME/.sh-tx-proxy → $REPO"
}

# 覆盖矩阵：每类会话跑一次，看 https_proxy 有没有被设上
# 「实测」= 真起一个该类型的 shell；「模拟」= /etc 级的钩子没法在演练环境里真挂，
# 改成把生成的钩子文件 source 进来，验证钩子内容本身是否正确。
check() {
    ensure_symlink
    local zshenv_hook="bash-登录(模拟)|bash -c '. \"$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh\" 2>/dev/null; echo \${https_proxy:-无}'"
    local -a rows=(
        "zsh-交互|HOME=\"$HOOKS_HOME\" ZDOTDIR=\"$HOOKS_HOME\" zsh -ic 'echo \${https_proxy:-无}'"
        "zsh-非交互|zsh -c '. \"$HOOKS_ETC/zsh/zshenv\" 2>/dev/null; echo \${https_proxy:-无}'"
        "bash-交互|HOME=\"$HOOKS_HOME\" bash -ic 'echo \${https_proxy:-无}'"
        "bash-登录|HOME=\"$HOOKS_HOME\" bash -lc 'echo \${https_proxy:-无}'"
        "bash-非交互|BASH_ENV=\"$REPO/proxy.sh\" bash -c 'echo \${https_proxy:-无}'"
        "sh/dash|sh -c '. \"$REPO/proxy.sh\" >/dev/null 2>&1; echo \${https_proxy:-无}'"
    )
    [ -f "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh" ] && rows+=("$zshenv_hook")
    say "== 会话覆盖矩阵（有地址=自动带上了）=="
    local r label cmd out
    for r in "${rows[@]}"; do
        label="${r%%|*}"; cmd="${r#*|}"
        out="$(eval "$cmd" 2>/dev/null | grep -oE 'http://[0-9.]+:[0-9]+|无' | tail -1)"
        printf '  %-16s %s\n' "$label" "${out:-无}"
    done
    say "  注：cron 默认 SHELL=/bin/sh(dash)，不吃 BASH_ENV，任务里要写 SHELL=/bin/bash 或显式 source。"
    say "  注：sudo 会清掉 BASH_ENV / 代理变量，需要就配 Defaults env_keep。"
    say "  注：systemd unit 不读上面任何一处，自己加 Environment=\"https_proxy=...\"。"
}

if [ "$CHECK_ONLY" = 1 ]; then check; exit 0; fi

if [ "$UNINSTALL" = 1 ]; then
    say "== 卸载本脚本加的钩子 =="
    for f in "$HOOKS_HOME/.bashrc" "$HOOKS_HOME/.zshrc" "$HOOKS_ETC/zsh/zshenv" "$HOOKS_ETC/environment"; do
        [ -f "$f" ] || continue
        grep -qF "$MARKER" "$f" 2>/dev/null || { skip "$f" "没有本脚本的标记"; continue; }
        cp -a "$f" "$f.bak-sh-tx-proxy-uninstall" 2>/dev/null
        # 删标记行 + 紧随其后的 source/BASH_ENV 行
        awk -v m="$MARKER" 'index($0,m){skip=1; next} skip && (/proxy\.sh/ || /BASH_ENV=/){skip=0; next} skip{skip=0} {print}' "$f" > "$f.tmp-sh-tx" \
            && mv "$f.tmp-sh-tx" "$f" && say "  清理  $f"
    done
    [ -f "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh" ] && rm -f "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh" && say "  删除  $HOOKS_ETC/profile.d/99-sh-tx-proxy.sh"
    say "完成。重开终端生效。"
    exit 0
fi

say "== 安装 hook：让所有会话自动带代理 =="
say "  仓库 $REPO"

if [ "$USER_MODE" = 1 ]; then
    say "- 用户级（交互终端）"
    append_once "$HOOKS_HOME/.bashrc" "$SRC_LINE"
    append_once "$HOOKS_HOME/.zshrc" "$SRC_LINE"
fi

if [ "$SYSTEM_MODE" = 1 ]; then
    say "- 系统级（登录 shell / 非交互 / cron）"
    if [ -d "$HOOKS_ETC/profile.d" ]; then
        if { echo "$MARKER"; echo "[ -r \"$REPO/proxy.sh\" ] && . \"$REPO/proxy.sh\""; } > "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh" 2>/dev/null; then
            chmod 644 "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh"
            say "  写入  $HOOKS_ETC/profile.d/99-sh-tx-proxy.sh  （所有登录 shell）"
        else
            skip "$HOOKS_ETC/profile.d/99-sh-tx-proxy.sh" "需要 root"
        fi
    fi
    append_once "$HOOKS_ETC/zsh/zshenv" "[ -r \"$REPO/proxy.sh\" ] && . \"$REPO/proxy.sh\""
    # BASH_ENV 覆盖 bash -c / 脚本 / cron 命令；pam_env 只吃字面路径，不做变量展开
    if ! grep -q '^BASH_ENV=' "$HOOKS_ETC/environment" 2>/dev/null; then
        printf '%s\nBASH_ENV=%s/proxy.sh\n' "$MARKER" "$REPO" >> "$HOOKS_ETC/environment" \
            && say "  写入  $HOOKS_ETC/environment  ← BASH_ENV（新登录会话起效，含 cron）" \
            || skip "$HOOKS_ETC/environment" "需要 root"
    else
        skip "$HOOKS_ETC/environment" "已有 BASH_ENV，不覆盖"
    fi
    say "  ⚠ systemd 服务不吃上面这些：unit 里自己加 Environment=\"https_proxy=http://...\""
    say "  ⚠ sudo 会清掉 BASH_ENV，需要就配 Defaults env_keep+=\"BASH_ENV\""
fi

say ""
check
