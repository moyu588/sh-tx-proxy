# sh-tx-proxy

在终端里手动切换 HTTP 代理的小脚本，**git 和 npm 跟着一起切**，不用再改第二处。

`proxy.sh` 提供五个命令：`p-sh` 切到上海代理，`p-tx` 切到 TX 代理，`poff` 关闭代理，`pst` 查看当前代理状态（含 git / npm 的生效值），`ptest` 探测两个代理地址哪个可达（两地办公用）。

脚本被 source 时**还会按本机网段自动选好一个代理**（`PROXY_DEFAULT=auto`，默认开着），新开终端不用手敲 `p-sh` / `p-tx`。

## 代理地址

| 命令 | 代理地址 | 说明 |
| --- | --- | --- |
| `p-sh` | `http://10.10.2.14:7890` | 上海 |
| `p-tx` | `http://10.100.36.162:7890` | TX |

两个地址都硬编码在 `proxy.sh` 顶部的 `PROXY_SH` / `PROXY_TX` 变量里，换地址直接改这两行即可（也支持用同名环境变量覆盖，不用改文件）。

## 开终端就带代理（自动选路）

source 脚本时会自动执行一次选路，所以**新终端不用再手敲 `p-sh` / `p-tx`**：

| `PROXY_DEFAULT` | 行为 |
| --- | --- |
| `auto`（默认） | 取本机 IPv4：`10.100.*` → TX，`10.10.*` → 上海；两个都不匹配就不设（当直连） |
| `sh` / `tx` | 固定用某一边，忽略网段 |
| `off`（或任意其它值） | 完全不自动设，退回纯手动 |

规则细节：

- **环境里已经有代理就一律不动**（父 shell 继承来的、脚本里显式 `export` 的、`PROXY_DEFAULT` 之外手动设的都算），`pst` 会标成 `来源 继承自环境`。
- 自动设时**不打印任何东西**，免得每开一个终端刷一行；要看就 `PROXY_DEFAULT_VERBOSE=1`，`pst` 里也永远有一行 `自动 本机 10.100.1.122 / PROXY_DEFAULT=auto → tx（…）`。
- `poff` 只关当前 shell。**同一个 shell 里再 source 一次（reload zshrc、zshenv 与 `~/.zshrc` 双挂）不会被重新设上** —— 靠 `PROXY_LOADED` 标记跳过，`pst` 的「来源」也保持原值不会被刷成 `继承自环境`。想开回来直接敲 `p-tx` / `p-sh`。
- 反过来，**下一个新终端还是会自动带上**（这是“免手动”的目的）。想让某个 shell 从头到尾不带代理：`export PROXY_DEFAULT=off` 之后再开 shell / source。
- 开销：一次 `hostname -I`（失败才退到 `ip` / `ifconfig`），实测 source 一遍约 8ms。

写法（在启动文件里 source 之前 export，就这台机器生效）：

```bash
export PROXY_DEFAULT=tx                     # 固定在 TX，不做网段判断
source ~/.sh-tx-proxy/proxy.sh
```

## 安装（每台服务器手动三步）

不建议再写 install.sh：改的是 shell 启动文件 + git 全局配置，脚本自动化踩到别人机器的概率比收益大。三步都是可回滚的手工命令：

```bash
# 1. 仓库固定在 /opt/github/sh-tx-proxy，再软链一份到 ~/.sh-tx-proxy
git clone https://github.com/moyu588/sh-tx-proxy.git /opt/github/sh-tx-proxy
ln -s /opt/github/sh-tx-proxy ~/.sh-tx-proxy

# 2. 让 shell 启动时加载（bash 和 zsh 各写一行，用哪个 shell 就写哪个 —— 两行都写上，别只写一个）
echo 'source ~/.sh-tx-proxy/proxy.sh' >> ~/.bashrc
echo 'source ~/.sh-tx-proxy/proxy.sh' >> ~/.zshrc

# 3. 一次性清掉 git 里写死的代理（不清这步 git 不会跟随切换，见下一节）
git config --global --unset http.proxy
git config --global --unset https.proxy
```

第 2 步 **bash 那行很容易漏**：只写 `~/.zshrc` 的话，交互 zsh 一切正常，但 `bash`、`sh`、`sudo -i`、以及任何非交互 shell 里连 `p-sh` 函数都没有，脚本导出的自动选路也不会跑（自动选路只在 source 发生时执行）。

**为什么用软链而不是直接 clone 到 `~/.sh-tx-proxy`**：机器上只有一份仓库，GitHub 上更新后 `cd /opt/github/sh-tx-proxy && git pull`，`~/.sh-tx-proxy` 透过软链自动同步，不存在两处副本各自漂移；启动文件里 source 的路径也永远是 `~/.sh-tx-proxy/proxy.sh`，换机器写法一致。

上面三步是「手动、可回滚、看得见」的装法。装完之后交互 zsh / 交互 bash 开终端即带代理（`proxy.sh` 会按网段自动选，见「开终端就带代理」一节），不需要任何日常操作。嫌脚本这层还绕、就想看得见摸得着的，直接抄「不想用命令切换：启动文件里写死静态 `export`」那一节。

以前已经 clone 到 `~/.sh-tx-proxy` 的老机器，改成软链（先确认没有本地未提交改动）：

```bash
git -C ~/.sh-tx-proxy status --short          # 应为空，非空先 commit 或 stash
mv ~/.sh-tx-proxy /opt/github/sh-tx-proxy     # /opt/github 不存在时先 mkdir -p
ln -s /opt/github/sh-tx-proxy ~/.sh-tx-proxy
```

装过旧版本、只是想更新命令的机器：`cd /opt/github/sh-tx-proxy && git pull` 再补第 3 步即可；命令名没变（`p-sh` / `p-tx` / `poff` / `pst`），实现从 alias 换成了函数。

第 3 步前先确认还有没有别的写死位置：

```bash
git config --list --show-origin | grep -i proxy
```

输出应为空。若出现 `remote.<name>.proxy` 或 `http.<url>.proxy`，按给出的 key 单独 `git config --global --unset <key>`。

npm 侧通常不用动：`~/.npmrc` 里就算有 `proxy=`，也会被脚本导出的 `npm_config_*` 覆盖。唯一例外是 `poff`——环境变量一撤，npm 就退回 `~/.npmrc` 里那个写死的值，所以想彻底干净就顺手删掉：

```bash
npm config delete proxy; npm config delete https-proxy; npm config delete noproxy
```

（`~/.npmrc` 里没有这几项的机器，上面三条会报 config key not found，忽略即可。）

## 推送凭据（只有要往 GitHub push 的机器需要）

仓库是 public，匿名 `git pull` / `git clone` 就能读，**只有写（push）才需要凭据**。远端 URL 保持 HTTPS，配 `~/.git-credentials`：

```bash
git config --global credential.helper store
echo 'https://moyu588:<Fine-grained PAT>@github.com' >> ~/.git-credentials
chmod 600 ~/.git-credentials
```

Token 在 GitHub → Settings → Developer settings → Fine-grained tokens 里建：Repository access 只勾 `moyu588/sh-tx-proxy`，Permissions → Contents 给 Read and write，务必设到期时间。

验证（`ls-remote` 匿名就能过，测不出写权限，要用 dry-run）：

```bash
cd /opt/github/sh-tx-proxy && git push --dry-run origin main
```

`~/.git-credentials` 是**明文文件**，`chmod 600` 只是最低限度防护：共享机、备份、镜像都会把 token 带出去。不想留明文就改用 `git config --global credential.helper 'cache --timeout=36000'`（内存缓存 10 小时，不落盘），代价是重启后要重新输一次。

日常同步：

```bash
cd /opt/github/sh-tx-proxy
git pull --rebase        # 拉 GitHub 上的更新，软链让 ~/.sh-tx-proxy 自动同步
git push origin main     # 本地改了 proxy.sh / README 之后推回去
```

## git 和 npm 为什么能跟着变

实测结论（npm 11.13.0 / git 2.47.2）：

| 工具 | 认什么 | 处理办法 |
| --- | --- | --- |
| curl、wget、git、Go、pip | `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy`（大小写两套） | 天然跟随，无需额外配置 |
| npm 7+ | **不认** `http_proxy`，只认 `npm_config_proxy` / `npm_config_https_proxy` / `npm_config_noproxy` 和 `~/.npmrc` | 脚本同时导出这三个 `npm_config_*` |
| git（例外） | `http.proxy` 等 git 配置的优先级 **高于** 环境变量 | 安装第 3 步清掉写死的配置 |

两条实测依据：

- npm：`http_proxy=http://1.2.3.4:7890 npm config get proxy` → `null`（npm 无视环境变量里的 `http_proxy`）；`~/.npmrc` 写 `proxy=http://9.9.9.9:1` 时，`npm_config_proxy=http://10.100.36.162:7890 npm config get proxy` → `http://10.100.36.162:7890`，即环境变量优先级高于 `~/.npmrc`，所以不用改 `.npmrc`。
- git：`git-config` 手册里 `http.proxy` 的原文是 “Override the HTTP proxy, normally configured using the http_proxy, https_proxy, and all_proxy environment variables”，即配置存在时环境变量被忽略。这台机器留着 `http.proxy=http://10.10.2.14:7890` 时 `git ls-remote https://github.com/...` 12 秒超时不返回；unset 之后仅靠环境变量，git 就朝 `https_proxy` 指的地址发出了 `CONNECT github.com:443`。

命令实现为函数而不是 alias：alias 在非交互 shell 里不展开（`bash -c 'source proxy.sh; p-tx'` 直接 command not found），函数在交互 shell、脚本、`bash -c` 里都能用。真正生效的是导出的环境变量，子进程自动继承，所以同一 shell 里跑的 `npm install`、构建脚本、`git pull` 都用同一个代理。

## 使用

**脚本必须用 `source` 加载**，因为它靠 `export` 修改当前 shell 的环境。直接 `./proxy.sh` 执行会在子进程里改完就退出，当前终端不受影响。

```bash
source ~/.sh-tx-proxy/proxy.sh

p-sh          # 代理: http://10.10.2.14:7890
p-tx          # 代理: http://10.100.36.162:7890
pst           # 当前 shell / npm / git 各自生效的代理 + 自动选路的判定结果
ptest         # 两个代理地址哪个可达（走直连探测，不会被当前代理骗出假阳性）
poff          # 代理已关闭（注意：下一个新终端还是会被自动选路设上，见上文）
```

## 命令一览

| 命令 / 变量 | 作用 |
| --- | --- |
| `p-sh` | 切换到上海代理 |
| `p-tx` | 切换到 TX 代理 |
| `pst` | 列出当前代理环境变量 + 来源 + 自动选路结果 + npm / git 的生效值 |
| `ptest` | 探测 `PROXY_SH` / `PROXY_TX` 的连通性（`--noproxy`，两地互测不串） |
| `poff` | 清空所有代理环境变量（含 `npm_config_*`） |
| `PROXY_DEFAULT` | `auto`（默认）/ `sh` / `tx` / `off`，控制 source 时是否自动选路 |
| `PROXY_DEFAULT_VERBOSE` | `1` 时自动选路打印一行说明，默认安静 |

`p-sh` / `p-tx` / `poff` / `pst` 都会在发现 git 配置写死代理时打警告，并把清理命令直接告诉你——警告消失即代表 git 已跟随环境变量。

## 直连白名单

无论走哪个代理，`no_proxy` / `NO_PROXY` 和 `npm_config_noproxy` 始终包含以下网段，内网访问不受影响：

```
localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12
```

需要改动就编辑 `proxy.sh` 里的 `NO_PROXY_LIST`（一处改完，环境变量和 npm 都跟着变）。

## 风险评估

| 项 | 说明 |
| --- | --- |
| 作用域 | 只影响当前 shell 及其子进程。source 时自动选路会把代理设上（写进启动文件即每个新终端自动带代理）。不同终端可以走不同代理，互不干扰。 |
| 自动选路的影响面 | 网段判断只对 `10.10.*` / `10.100.*` 生效，认不出来就当直连，不会瞎设一个不可用的代理。副作用是：**这台机器上所有 source 过启动文件的 shell 默认都出网走代理**，内网靠 `no_proxy` 直连；不想带代理的会话用 `PROXY_DEFAULT=off` 起，或进去再 `poff`。 |
| 不落盘 | 不写 `~/.gitconfig`、不写 `~/.npmrc`，所以不存在“一个终端 `poff` 把别的会话弄坏”的问题。 |
| 唯一的破坏性步骤 | 安装第 3 步删掉 `~/.gitconfig` 里写死的 `http.proxy`。之后凡是**没有 source 过启动文件**的场合（cron、systemd unit、`docker exec`、`bash -c` 这类非交互 shell、某些 CI runner、agent 会话）git 会变成直连——注意不是“退回直连就通了”，而是**直连等超时**：实测同一台机器不带代理 `git ls-remote` 卡到 12s 超时（`timeout 12` 退出码 124），带代理 0.7s 返回。如果那个场合必须走代理，两种处理：任务里显式 `export https_proxy=...`（或 `. ~/.sh-tx-proxy/proxy.sh`）；或只给那个仓库配代理 `git -C /path/repo config http.proxy http://10.100.36.162:7890`（写进 `.git/config`，不影响其他 shell 的切换）。 |
| 回滚 | `git config --global http.proxy http://10.10.2.14:7890` 一行恢复原样；删掉 `~/.bashrc` / `~/.zshrc` 里的 source 行即可完全退出这套脚本；只想停自动选路就 `export PROXY_DEFAULT=off`。 |
| npm 副作用 | `npm_config_proxy` / `npm_config_https_proxy` / `npm_config_noproxy` 会被同 shell 里所有走 npm 配置约定的程序（npm、npx、node-gyp 等）读取，仅当前 shell 有效。不想带代理跑 npm 就 `poff` 或另开终端；但如果 `~/.npmrc` 里写过 `proxy=`，`poff` 之后 npm 会退回那个值（见安装一节的 `npm config delete`）。 |
| 工具兼容性 | `10.0.0.0/8` 这类 CIDR 写法，curl、git、Go 程序能识别；Python `requests` 等只做后缀匹配的工具看不懂，可能需要改成逐个 IP 或域名后缀。npm 的 `noproxy` 同样按 npm 自己的匹配规则处理，遇到内网 registry 走了代理就往这一项排查。 |

## 排查“代理怎么没了”

按这个顺序走，一步一个结论，别猜：

```bash
pst                      # 1. 当前 shell 到底有没有；看「来源」行和「自动」行
type p-sh                # 2. 这个 shell 有没有 source 过（bash / 非交互 shell 常在这一步露馅）
ptest                    # 3. 两个代理地址本身可达吗（不可达就不是 shell 的问题）
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com   # 4. 端到端
```

- `pst` 显示 `未设置代理` + `自动 … → 不自动设`：`PROXY_DEFAULT` 被设成 `off`／本机 IP 认不出来／没 source。
- `pst` 显示有代理但 `curl` 卡住：`ptest` 跑一下，多半是代理端（clash 没起、没开 allow-lan、主机防火墙入站被策略挡）。特征是 **SYN 无回音（`filtered`）而不是 `closed`**——`closed` 说明包已经进到 TCP 栈、只是没人监听；`filtered` 说明包根本没进去，加在本地防火墙的放行规则未必生效（域策略 `AllowInboundRules=False`、或杀软接管过滤时就是这种）。
- 只有国内站通、google/github 干等超时：代理没在工作，本机本身没有翻墙出口，不要误判成“直连能用”。

## 不想用命令切换：启动文件里写死静态 `export`

最省事的路线：不碰这套脚本的命令，直接把代理写进 shell 启动文件，开终端就有，和用不用本仓库无关。

```bash
# ~/.zshrc 和 ~/.bashrc 各贴一份（TX 端；上海端换成 http://10.10.2.14:7890）
export http_proxy=http://10.100.36.162:7890
export https_proxy=$http_proxy
export all_proxy=$http_proxy
export no_proxy=localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12
export npm_config_proxy=$http_proxy npm_config_https_proxy=$http_proxy npm_config_noproxy=$no_proxy
```

三个必须知道的点：

1. **`~/.zshrc` 里原有的注释行是上海地址**（`10.10.2.14:7890`），人在 TX 时直接取消注释就废了 —— 地址必须按当前办公地点核对，别照抄。
2. **npm 不读 `http_proxy`**，所以 `npm_config_*` 那两行不能省（实测：`http_proxy=http://1.2.3.4:7890 npm config get proxy` → `null`）。curl / wget / git / Go / pip 只靠前四行就跟着走。
3. **git 里不能再写死 `http.proxy`**，它优先级高于环境变量，写死之后静态 `export` 对 git 无效：
   ```bash
   git config --list --show-origin | grep -i proxy   # 输出必须为空
   ```

写了静态 `export`，`proxy.sh` 的自动选路会让位（环境里已有代理就不动，`pst` 标 `来源 继承自环境`），但 `p-sh` / `p-tx` / `pst` / `ptest` 仍然可用：临时切另一头就敲一下命令，**同一个 shell 里命令优先，重开终端又回到静态值**。两者并存不冲突，静态是默认值，命令是临时改道。

静态路线盖不住的场景（要覆盖就得回到“多入口钩子”那套，或单独处理）：

| 场景 | 结果 | 单独处理 |
| --- | --- | --- |
| 交互 zsh / 交互 bash | ✅ 有代理 | — |
| `bash -l` 登录 shell | 看 `~/.profile`，bash 交互只读 `~/.bashrc` | 同一份 export 也写进 `~/.profile` |
| `bash -c`、脚本、agent 会话 | ❌ 没有（非交互不读 rc 文件） | 任务里显式 `export https_proxy=...` |
| cron | ❌ 默认 `/bin/sh` | crontab 顶部 `SHELL=/bin/bash` + 显式 export |
| sudo | ❌ 被清掉 | `Defaults env_keep += "http_proxy https_proxy no_proxy"` |
| systemd unit | ❌ 不读 shell 配置 | unit 里 `Environment="https_proxy=http://10.100.36.162:7890"` |

> 本机（`kalitest` / 10.100.1.122，TX 段）当前状态：交互 zsh 由 `~/.zshrc` 里 `source proxy.sh` + 自动选路带代理；`~/.bashrc` 未挂任何东西。曾试过把 `source` 挂到 `/etc/profile.d`、`/etc/zsh/zshenv`、`/etc/environment(BASH_ENV)` 做全会话覆盖，评估后觉得没必要，回退为上面这种静态写法，只改自己两个 rc 文件。

## 扩展

公司再加一套代理环境，照抄 `PROXY_SH` / `p-sh()` 的模式加一组即可，`pst` 里的地名识别也跟着加一行 `case`。自动选路要在 `_proxy_pick` 的 `case` 里补一条网段匹配（`10.200.*` → 新地名），别忘了 `10.10.*` 这种前缀重叠的段要把**更具体的写在前面**。
