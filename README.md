# set-proxy.sh —— 一条命令把代理写进各工具自己的配置

单文件、无依赖、可独立使用。**不依赖 source、不依赖 shell 函数、不依赖任何仓库**。
配一次之后，新开的终端、脚本、工具自动带代理，不需要再敲 `p-tx` / `p-sh` 之类命令。

装法用**软链**（别拷副本，否则会和仓库漂移）：

```bash
ln -sf /opt/github/sh-tx-proxy/set-proxy.sh /usr/local/bin/set-proxy.sh
set-proxy.sh tx            # TX 代理；默认不碰 /etc、不需要 root
set-proxy.sh show          # 自检：每一处配置 + 端到端
```

`/usr/local/bin` 在 PATH 里，所以能直接敲 `set-proxy.sh`；软链指向仓库，以后 `git pull` 更新即生效，无第二份拷贝。

---

## 一、`.bashrc` / `.zshrc` 够不够？—— 不够，实测漏三类会话

| 会话类型 | 只写 .bashrc/.zshrc | 本脚本（4 个 rc） | 靠哪个文件 |
| --- | --- | --- | --- |
| `bash -ic` 交互 bash | ✅ | ✅ | `~/.bashrc` |
| `bash -lc` 登录 bash | ❌ | ✅ | `~/.profile` |
| `bash -c` 非交互 bash / 脚本 | ❌ | ❌（有意） | 无解 → `--env` |
| `zsh -ic` 交互 zsh | ✅ | ✅ | `~/.zshrc` |
| `zsh -c` 非交互 zsh / 脚本 | ❌ | ✅ | `~/.zshenv` |
| `zsh -lc` 登录 zsh | ❌ | ✅ | `~/.zshenv` |
| `sh -lc` 登录 sh | ❌ | ✅ | `~/.profile` |

两个坑的成因（都实测过）：

1. **`bash -c` 读不到**：Kali 的 `~/.bashrc` 第 6-8 行是 `case $- in *i*) ;; *) return;; esac`，非交互直接 `return`，
   所以追加在文件**末尾**的代理块执行不到；把 `BASH_ENV` 指向 `~/.bashrc` 也被同一行挡住（实测无效）。
2. **`zsh -c` / `zsh -lc` 读不到 `.zshrc`**：zsh 的启动文件按用途分 —— `.zshenv` 每次调用都读，`.zprofile` 登录读，
   `.zshrc` **只有交互式**才读。对照实验：无 `.zshenv` 时 `zsh -c` 无代理，加上就有。

所以脚本写 **4 个** rc 文件：`.bashrc`（交互 bash）、`.zshrc`（交互 zsh）、`.zshenv`（所有 zsh）、`.profile`（登录 shell）。

> 特意**不写** `~/.bash_profile`：bash 登录只读「`.bash_profile` → `.bash_login` → `.profile`」里**第一个存在的**，
> 凭空创建它会遮蔽 `.profile`，把 PATH、pipx 路径等一起搞丢。

---

## 二、写到哪里（默认 + 开关）

**默认（不带任何开关）**：只写下面这些，**完全不碰 `/etc`、不需要 root**（实测：演练时假 `/etc` 目录 0 个文件）。

| 写入位置 | 管什么 | 验证方式 |
| --- | --- | --- |
| `~/.bashrc` `~/.zshrc` `~/.zshenv` `~/.profile` | 各类 shell 会话（见上表） | 7 类会话逐一实测 |
| `~/.gitconfig` → `http.proxy` / `https.proxy` | git（优先级高于环境变量，任何 shell 都一致） | 清空环境变量后 `git ls-remote github` 返回 SHA |
| `~/.npmrc` → `proxy` / `https-proxy` / `noproxy` | npm / npx / node-gyp（npm **不读** `http_proxy`） | 清空环境变量后 `npm ping` → PONG |
| `~/.curlrc` → `proxy` / `noproxy` | curl | 清空环境变量后 `curl` 拉 github 200 |
| `~/.wgetrc` → `use_proxy` / `http_proxy` / `no_proxy` | wget | 清空环境变量后 github 200 |
| `~/.config/pip/pip.conf` → `global.proxy` / `global.noproxy` | pip 走代理（若 pip 已配国内镜像则本项非必需） | `pip download requests` 成功 |

**可选开关**（不点名就不生效）：

| 开关 | 做什么 | 为什么保留它 |
| --- | --- | --- |
| `--env` | 写 `/etc/environment`（需 root） | **只认环境变量**的程序：`python requests` / `urllib` 没有任何自己的配置文件入口（实测清空 env 后 `urllib.getproxies()` 返回 `{}`），另外 cron、`su -`、新 ssh 登录也靠它。投递机制已确认：`/etc/pam.d/{sshd,login,su}` 都有 `pam_env`，`su - root` 能读到只存在于 `/etc/environment` 的键。**只对之后新登录的会话生效** |
| `--go` | `go env -w GOPROXY=https://goproxy.cn,direct` | 本机 `GOPROXY` 默认是 `proxy.golang.org`，`go get` 要翻墙；换成国内镜像后不需要代理。写的是 `~/.config/go/env`，不吃环境变量 |
| `--everything` | `--env` + `--go` | |
| `--sweep` | 清掉 rc 里残留的 `source ~/.sh-tx-proxy/proxy.sh` | 弃用旧项目时用 |

`no_proxy` 全处统一为 `localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12`（自检里内网请求返回 `401`＝命中服务而非绕代理）。

### 已砍掉的开关及原因

早期版本还有 `--apt` / `--docker` / `--systemd` / `--gem`，评估后删除，理由是"能覆盖"不等于"用得上"：

| 砍掉的 | 原因（本机实测） |
| --- | --- |
| `--apt` | apt 不需要代理：直连 `http.kali.org` **200 / 1.2s**、`deb.debian.org` **200 / 0.3s** |
| `--docker` | 本机**没装 docker/podman**，写了也只是预埋。将来要用：`~/.docker/config.json` 的 `proxies.default`（容器内程序）+ `docker.service` 的 `Environment=`（守护进程拉镜像） |
| `--systemd` | 本机服务走内网（`artex.service` 的 LLM 是 `10.100.4.43:3425`），不需要出墙。将来需要就在 unit 里写 `Environment="https_proxy=..."` |
| `--gem` | 不 `gem install` 就毫无作用；需要时 `~/.gemrc` 写 `:proxy: <url>` 即可（`Gem.configuration[:proxy]` 会读到） |

---

## 三、用法

```bash
bash set-proxy.sh tx                  # TX 10.100.36.162:7890
bash set-proxy.sh sh                  # 上海 10.10.2.14:7890
bash set-proxy.sh http://1.2.3.4:7890 # 任意地址
bash set-proxy.sh show                # 自检
bash set-proxy.sh off                 # 撤销（带过开关的也要带上，见下）
bash set-proxy.sh tx --everything     # 再加 /etc/environment 与 GOPROXY（需 root）
bash set-proxy.sh tx --sweep          # 顺带清旧项目残留
```

- 覆盖默认地址：`PROXY_SH` / `PROXY_TX` / `NO_PROXY_LIST` / `GOPROXY_MIRROR` 环境变量。
- 演练（不碰真系统）：`SET_PROXY_HOME=/tmp/h SET_PROXY_ETC_DIR=/tmp/e bash set-proxy.sh tx --everything`
- **撤销要带同样的开关**：`--env` 写的 `/etc/environment`、`--go` 写的 GOPROXY，只有 `off` 时也带上才会被清掉（避免误删你没让脚本碰的东西）。

---

## 四、安全性设计

| 机制 | 说明 |
| --- | --- |
| 标记块 | 内容都包在 `# ---- proxy (managed by set-proxy.sh) ----` … `# ---- proxy end ----` 之间，重复执行只替换该块，**不堆叠**（实测连跑两次，块数与 `http_proxy` 行数恒为 1） |
| 备份 | 首次改动某文件留 `<文件>.bak-set-proxy` |
| 逐字节还原 | `off` 后 `.bashrc`/`.zshrc`/`.profile`/`/etc/environment` 与改动前**逐字节一致**（以改动前备份为基线 `cmp` 验证） |
| 零残留 | 三轮 SET/OFF 循环后文件集合不变；脚本建的 `.zshenv`、`.curlrc`、`.wgetrc`、`pip.conf` 在 `off` 后删除（含 0 字节文件、只剩 `[global]` 的 pip 空壳、空目录） |
| 拒绝危险情况 | `HOME` 为空或不可写直接退出（不会误写 `/.bashrc`）；`HOME` 为空会先按当前 uid 从 passwd 查家目录 |
| 不做的事 | 不碰 `~/.bash_profile`/`~/.bash_login`；不覆盖别人的配置（`/etc/environment` 里的其它键、`.npmrc` 里的 `yes=true` 等原样保留） |

---

## 五、自检

```bash
bash set-proxy.sh show
```

输出两部分：**每一处当前配置**（rc 四个文件有无块及取值、git、npm、curl、wget、pip、GOPROXY、`/etc/environment`、当前会话 env、旧 `proxy.sh` 残留）与**端到端自检**（curl 拉 github、python requests、git ls-remote、内网直连）。
`python` 那行只有在 `--env` 存在时才会注入变量去实测，否则直接说明"它只认环境变量，所以跳过"。

---

## 六、常见问题

**Q：改完当前终端怎么没代理？**
rc 文件只对新开的 shell 生效。当前终端 `source ~/.zshrc`（或 `~/.bashrc`）；已在运行的进程/服务要重启才吃到。

**Q：`bash -c` / 我的脚本里为什么还是没有？**
这是 `.bashrc` 对非交互提前 `return` 导致的，rc 层面无解。加 `--env`（`/etc/environment`，PAM 会话注入，**需要重新登录**），或在该脚本里显式 `export`。

**Q：cron / systemd 服务呢？**
cron 走 PAM，`--env` 能覆盖（重新登录后生效）。systemd 服务不读任何 shell 配置，在 unit 里写 `Environment="https_proxy=http://10.100.36.162:7890"`；本机现有服务走内网，不需要。

**Q：`sudo` 之后代理没了？**
sudo 默认清空环境变量。需要就 `Defaults env_keep += "http_proxy https_proxy no_proxy"`；但 git/npm/curl 等仍会读它们自己的配置文件，多数情况不受影响。

**Q：python 为什么必须靠 `--env`？**
`requests` / `urllib` 只读环境变量，没有任何配置文件入口。要么 `--env`，要么在代码/命令里显式传 `proxies=`。

**Q：换办公地点？**
`set-proxy.sh sh`（或 `tx`）一条命令全机改过来；若用过 `--env`，记得带上开关（并重新登录）。

**Q：代理所在机器（Windows 上的 clash）睡眠/关机了？**
配置仍指向该地址，表现是外网命令慢超时而非快速失败。`show` 的端到端自检立刻能看出来；也可让 git 快速失败：
`git config --global http.lowSpeedLimit 1000; git config --global http.lowSpeedTime 10`。

**Q：旧的 sh-tx-proxy（`proxy.sh` 的 `p-sh`/`p-tx`/`pst`）？**
`proxy.sh` 已从仓库删除，rc 里也不再有 `source proxy.sh`（`--sweep` 清过，`show` 里「旧 proxy.sh 残留 = 无」）。
若还想彻底收尾，只剩删一个软链：`rm -f ~/.sh-tx-proxy`。仓库本身**别删**，见下节。

---

## 七、文件清单与体量

```
set-proxy.sh   本脚本（单文件，仓库里那份即唯一真源）—— 234 行（含注释），有效代码 183 行，18 个函数
README.md      本文档
```

仓库 `/opt/github/sh-tx-proxy` 是 `set-proxy.sh` 的家，且 `/usr/local/bin/set-proxy.sh` 软链指过去。
**所以不要 `rm -rf` 仓库**（会把脚本本体删掉、软链变断链）。日常更新走：

```bash
cd /opt/github/sh-tx-proxy && git pull          # 软链自动指向新内容，无需重装
set-proxy.sh show                               # 拉完顺手自检一下
```

唯一还能从旧项目留下的东西是软链 `~/.sh-tx-proxy`（指向本仓库，已无人引用），要清就：

```bash
rm -f ~/.sh-tx-proxy
```