# sh-tx-proxy

在终端里手动切换 HTTP 代理的小脚本，**git 和 npm 跟着一起切**，不用再改第二处。

`proxy.sh` 提供五个命令：`p-sh` 切到上海代理，`p-tx` 切到 TX 代理，`poff` 关闭代理，`pst` 查看当前代理状态（含 git / npm 的生效值），`ptest` 探测两个代理地址哪个可达（两地办公用）。

## 代理地址

| 命令 | 代理地址 | 说明 |
| --- | --- | --- |
| `p-sh` | `http://10.10.2.14:7890` | 上海 |
| `p-tx` | `http://10.100.36.162:7890` | TX |

两个地址都硬编码在 `proxy.sh` 顶部的 `PROXY_SH` / `PROXY_TX` 变量里，换地址直接改这两行即可。

## 安装（每台服务器手动三步）

不建议再写 install.sh：改的是 shell 启动文件 + git 全局配置，脚本自动化踩到别人机器的概率比收益大。三步都是可回滚的手工命令：

```bash
# 1. 仓库固定在 /opt/github/sh-tx-proxy，再软链一份到 ~/.sh-tx-proxy
git clone https://github.com/moyu588/sh-tx-proxy.git /opt/github/sh-tx-proxy
ln -s /opt/github/sh-tx-proxy ~/.sh-tx-proxy

# 2. 让 shell 启动时加载（bash 和 zsh 各写一行，用哪个 shell 就写哪个）
echo 'source ~/.sh-tx-proxy/proxy.sh' >> ~/.bashrc
echo 'source ~/.sh-tx-proxy/proxy.sh' >> ~/.zshrc

# 3. 一次性清掉 git 里写死的代理（不清这步 git 不会跟随切换，见下一节）
git config --global --unset http.proxy
git config --global --unset https.proxy
```

**为什么用软链而不是直接 clone 到 `~/.sh-tx-proxy`**：机器上只有一份仓库，GitHub 上更新后 `cd /opt/github/sh-tx-proxy && git pull`，`~/.sh-tx-proxy` 透过软链自动同步，不存在两处副本各自漂移；启动文件里 source 的路径也永远是 `~/.sh-tx-proxy/proxy.sh`，换机器写法一致。

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
pst           # 当前 shell / npm / git 各自生效的代理
ptest         # 两个代理地址哪个可达
poff          # 代理已关闭
```

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `p-sh` | 切换到上海代理 |
| `p-tx` | 切换到 TX 代理 |
| `pst` | 列出当前代理环境变量 + npm / git 的生效值 |
| `ptest` | 探测 `PROXY_SH` / `PROXY_TX` 的连通性 |
| `poff` | 清空所有代理环境变量（含 `npm_config_*`） |

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
| 作用域 | 只影响当前 shell 及其子进程。新开终端需重新加载（写进启动文件即自动）。不同终端可以走不同代理，互不干扰。 |
| 不落盘 | 不写 `~/.gitconfig`、不写 `~/.npmrc`，所以不存在“一个终端 `poff` 把别的会话弄坏”的问题。 |
| 唯一的破坏性步骤 | 安装第 3 步删掉 `~/.gitconfig` 里写死的 `http.proxy`。之后凡是**没有 source 过启动文件**的场合（cron、systemd unit、`docker exec` 起来的非登录 shell、某些 CI runner）git 会变成直连。如果那台机器必须走代理，两种处理：在任务里显式 `export https_proxy=...`，或者只给那个仓库配代理 `git -C /path/repo config http.proxy http://10.10.2.14:7890`（写进 `.git/config`，不影响其他 shell 的切换）。 |
| 回滚 | `git config --global http.proxy http://10.10.2.14:7890` 一行恢复原样；删掉 `~/.bashrc` / `~/.zshrc` 里的 source 行即可完全退出这套脚本。 |
| npm 副作用 | `npm_config_proxy` / `npm_config_https_proxy` / `npm_config_noproxy` 会被同 shell 里所有走 npm 配置约定的程序（npm、npx、node-gyp 等）读取，仅当前 shell 有效。不想带代理跑 npm 就 `poff` 或另开终端；但如果 `~/.npmrc` 里写过 `proxy=`，`poff` 之后 npm 会退回那个值（见安装一节的 `npm config delete`）。 |
| 工具兼容性 | `10.0.0.0/8` 这类 CIDR 写法，curl、git、Go 程序能识别；Python `requests` 等只做后缀匹配的工具看不懂，可能需要改成逐个 IP 或域名后缀。npm 的 `noproxy` 同样按 npm 自己的匹配规则处理，遇到内网 registry 走了代理就往这一项排查。 |

## 扩展

公司再加一套代理环境，照抄 `PROXY_SH` / `p-sh()` 的模式加一组即可，`pst` 里的地名识别也跟着加一行 `case`。
