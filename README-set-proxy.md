# set-proxy.sh —— 一条命令把代理写死到各工具

单文件、无依赖、可独立使用的代理配置脚本。**不依赖 source、不依赖 shell 函数、不依赖任何仓库**。
配一次之后，新开的终端、脚本、工具都自动带代理，不需要再敲 `p-tx` 之类的命令。

```bash
cp set-proxy.sh /root/bin/ && chmod 755 /root/bin/set-proxy.sh   # 建议放到固定位置
bash /root/bin/set-proxy.sh tx --everything                      # TX 代理，全量覆盖（需 root）
bash /root/bin/set-proxy.sh show                                 # 自检：每一处配置 + 端到端
```

---

## 一、先说结论：`.bashrc` / `.zshrc` 够不够？

**不够。** 只写 `.bashrc` + `.zshrc` 会漏掉两类很常见的会话。实测（本机 Kali，root，TX 段 `10.100.1.122`）：

| 会话类型 | 只写 .bashrc/.zshrc | 本脚本（4 个文件） | 靠哪个文件生效 |
| --- | --- | --- | --- |
| `bash -ic` 交互 bash | ✅ | ✅ | `~/.bashrc` |
| `bash -lc` 登录 bash | ❌ | ✅ | `~/.profile` |
| `bash -c` 非交互 bash / bash 脚本 | ❌ | ❌（**有意的**，见下） | 无解 → 用 `--env` |
| `zsh -ic` 交互 zsh | ✅ | ✅ | `~/.zshrc` |
| `zsh -c` 非交互 zsh / zsh 脚本 | ❌ | ✅ | `~/.zshenv` |
| `zsh -lc` 登录 zsh | ❌ | ✅ | `~/.zshenv` |
| `sh -lc` 登录 sh | ❌ | ✅ | `~/.profile` |

两个坑的成因：

1. **`bash -c` 永远读不到**：Kali 的 `~/.bashrc` 第 6-8 行是

   ```bash
   case $- in
       *i*) ;;
         *) return;;
   ```

   非交互 shell 直接 `return`，所以追加在文件**末尾**的代理块根本执行不到。把 `BASH_ENV` 指向 `~/.bashrc` 同样会被这行挡住（实测确认）。
2. **`zsh -c` / `zsh -lc` 读不到 `.zshrc`**：zsh 的启动文件是按用途分的 —— `.zshenv` 每次调用都读，`.zprofile` 登录读，`.zshrc` **只有交互式**才读。所以只写 `.zshrc` 时，`zsh -c '...'` 这类脚本里没有代理。

因此脚本写 **4 个** rc 文件，各管一段：

| 文件 | 管的会话 | 备注 |
| --- | --- | --- |
| `~/.bashrc` | 交互 bash | 对非交互提前 return，无法覆盖 |
| `~/.zshrc` | 交互 zsh | |
| `~/.zshenv` | **所有** zsh（含 `zsh -c`、`zsh -lc`） | 少了它，zsh 脚本就没代理；root 的登录 shell 是 zsh，所以 `su - root -c '...'` 也由它覆盖（等价于实测过的 `zsh -lc`） |
| `~/.profile` | 登录 shell：`bash -l`、`sh -l` | 本机无 `~/.bash_profile`/`~/.bash_login`，所以 bash 登录读这个 |

> **为什么不写 `~/.bash_profile`**：bash 登录时只读「`~/.bash_profile` → `~/.bash_login` → `~/.profile`」里**第一个存在的**。凭空创建 `~/.bash_profile` 会把原有的 `~/.profile` 遮蔽掉（PATH、pipx 路径等全部失效），所以脚本只碰 `~/.profile`。

`bash -c` 这类非交互 bash 由 rc 文件确实覆盖不到，交给 `--env`（`/etc/environment`，PAM 会话注入）或 `--systemd`（服务）。

---

## 二、`--everything` 到底写了哪些地方

| 写入位置 | 管什么 | 怎么验证的 |
| --- | --- | --- |
| `~/.bashrc` `~/.zshrc` `~/.zshenv` `~/.profile` | 各类 shell 会话（见上表） | 7 类会话逐一实测，见上表 |
| `~/.gitconfig` → `http.proxy` / `https.proxy` | git（优先级高于环境变量，所以任何 shell 都一致） | 清空环境变量后 `git ls-remote github` 返回 SHA |
| `~/.npmrc` → `proxy` / `https-proxy` / `noproxy` | npm / npx / node-gyp | 清空环境变量后 `npm ping` → PONG |
| `~/.curlrc` → `proxy` / `noproxy` | curl | `curl -K ~/.curlrc` google 200 |
| `~/.wgetrc` → `use_proxy` / `http_proxy` / `no_proxy` | wget | 清空环境变量后 wget github 200 |
| `~/.config/pip/pip.conf` → `global.proxy` / `global.noproxy` | pip / pip3 | `pip download requests` 成功 |
| `/etc/environment`（`--env`） | **只认环境变量的那批**：`python requests` / `urllib`、Go 编译出的程序、cron、`su -`、ssh 登录 | `python requests` 只认 env（清空 env 后 `urllib.getproxies()` 返回 `{}`，官方无配置文件入口）；把块里的变量注入进程后 google 200；PAM 投递机制单独验证（`/etc/pam.d/{sshd,login,su}` 都有 `pam_env`，`su - root` 能读到只存在于 `/etc/environment` 的键） |
| `/etc/systemd/system.conf.d/99-set-proxy.conf`（`--systemd`） | 所有 systemd 服务 | 写文件正确性已验证；生效需 `systemctl daemon-reexec` 或重启 |
| `~/.docker/config.json` 的 `proxies.default`（`--docker`） | docker run / build 容器内的程序 | **本机未装 docker**，JSON 结构与官方键名已校验，属预埋；守护进程自己拉镜像不吃这个文件，要另给 `docker.service` 加 `Environment=` |
| `go env -w GOPROXY=https://goproxy.cn,direct`（`--go`） | Go 模块下载（走国内镜像，不需要翻墙） | 写入 `~/.config/go/env`，`go env GOPROXY` 读回确认；Go 程序运行时仍读 env → 配合 `--env` |
| `~/.gemrc` 的 `:proxy:`（`--gem`） | RubyGems | `Gem.configuration[:proxy]` 读回确认 |
| `/etc/apt/apt.conf.d/95proxy`（`--apt`） | apt / debian 系包管理 | apt 标准配置项 |

`no_proxy` 全处统一为 `localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12`，内网直连（自检里那条内网请求返回 `401`＝命中服务而非绕代理，说明白名单生效）。

---

## 三、用法

```bash
bash set-proxy.sh tx                 # TX 10.100.36.162:7890
bash set-proxy.sh sh                 # 上海 10.10.2.14:7890
bash set-proxy.sh http://1.2.3.4:7890 # 任意地址
bash set-proxy.sh off                # 撤销（必须带上当初用过的同样开关，见下）
bash set-proxy.sh show               # 自检
bash set-proxy.sh tx --everything    # 全量：rc + 工具 + /etc/environment + systemd + docker + go + gem + apt
bash set-proxy.sh tx --sweep         # 顺带清掉 rc 里残留的 source ~/.sh-tx-proxy/proxy.sh
```

单个开关（按需，不用全上）：

`--env` · `--systemd` · `--docker` · `--go` · `--gem` · `--apt` · `--everything`

- 不写任何开关 = 只配 shell 四个 rc + git/npm/curl/wget/pip（不需要 root）。
- 需要写 `/etc` 的（`--env` `--systemd` `--apt`）必须 root。
- 覆盖默认地址：`PROXY_SH` / `PROXY_TX` / `NO_PROXY_LIST` / `GOPROXY_MIRROR` 环境变量。
- 演练（不碰真系统）：`SET_PROXY_HOME=/tmp/h SET_PROXY_ETC_DIR=/tmp/e bash set-proxy.sh tx --everything`

**撤销要带同样的开关**：`--env` 写的 `/etc/environment`、`--docker` 写的 config.json 等，只有在 `off` 时也带上对应开关才会被清掉（避免误删你没让脚本碰过的东西）。

---

## 四、安全性设计

| 机制 | 说明 |
| --- | --- |
| 标记块 | 所有内容都写在 `# ---- proxy (managed by set-proxy.sh) ----` 和 `# ---- proxy end ----` 之间。重复执行只替换这一块，**不堆叠**（实测连跑 2 次，块数与 `http_proxy` 行数恒为 1） |
| 备份 | 首次改动某文件时留 `<文件>.bak-set-proxy`，可手工回滚 |
| 逐字节还原 | `off` 后 `.bashrc`/`.zshrc`/`.profile`/`/etc/environment` 与改动前**逐字节一致**（用改动前的备份做基线 `cmp` 验证） |
| 零残留 | 三轮 SET/OFF 循环后文件集合不变；脚本自己创建的 `.zshenv`、`.curlrc`、`.wgetrc`、`.gemrc`、`.docker/config.json`、`pip.conf`、apt 95proxy 在 `off` 后会被删除（含空的 `[global]` 壳、0 字节文件、空目录） |
| 拒绝危险情况 | `HOME` 为空或不可写时直接退出（不会误写 `/.bashrc`）；`HOME` 为空会先尝试从 passwd 查家目录 |
| 不做的事 | 不碰 `~/.bash_profile`/`~/.bash_login`（会遮蔽 `~/.profile`）；不覆盖已有的非本脚本配置（`/etc/environment` 里的其它键、`.npmrc` 里的 `yes=true` 等都原样保留） |

---

## 五、自检

```bash
bash set-proxy.sh show
```

输出两部分：**每一处当前配置**（rc 块、git、npm、curl、wget、pip、docker、go、gem、`/etc/environment`、systemd、apt、当前会话 env、旧 `proxy.sh` 残留）和**端到端自检**（curl、python requests、git ls-remote、内网直连）。

---

## 六、常见问题

**Q：改完当前终端怎么没代理？**
rc 文件只对新开的 shell 生效。当前终端 `source ~/.zshrc`（或 `~/.bashrc`）即可；已经在跑的进程/服务要重启才吃到。

**Q：cron / systemd 服务为什么还是没有？**
它们不读 shell 启动文件。解法：`--env`（PAM 会话，含 cron，**需要重新登录**）和 `--systemd`（所有服务，需 `systemctl daemon-reexec` 或重启）。只想给个别 unit，就别开 `--systemd`，改在 unit 里写 `Environment="https_proxy=..."`。

**Q：`sudo` 之后代理没了？**
sudo 默认清空环境变量。需要就 `Defaults env_keep += "http_proxy https_proxy no_proxy"`（但 git/npm 等仍会读它们自己的配置文件，多数情况不受影响）。

**Q：python 为什么必须靠 `--env`？**
`requests` / `urllib` 只读环境变量，没有任何自己的配置文件入口（实测：清空 env 后 `urllib.getproxies()` 返回 `{}`）。所以要么 `--env`，要么在代码/命令里显式传 `proxies=`。

**Q：换办公地点怎么办？**
`bash /root/bin/set-proxy.sh sh`（或 `tx`）一条命令全机改过来，含 git/npm/curl/wget/pip 与 `/etc/environment`、systemd（后两者要带对应开关 + 重新登录/reexec）。

**Q：代理所在机器（如 Windows 上的 clash）睡眠/关机了？**
配置仍然指向那个地址，表现为外网命令慢超时而不是快速失败。`show` 的端到端自检能立刻看出来；也可以给 git 加快速失败：`git config --global http.lowSpeedLimit 1000; git config --global http.lowSpeedTime 10`。

**Q：和旧的 sh-tx-proxy（`proxy.sh` 的 `p-sh`/`p-tx`/`pst`）冲突吗？**
不冲突也不依赖。旧脚本只影响 source 过它的 shell；本脚本写的是各工具自己的配置文件，覆盖面更广。彻底切过来：`bash set-proxy.sh tx --sweep`（清残留 source 行），再删仓库与 `~/.sh-tx-proxy` 软链。

---

## 七、文件清单

```
set-proxy.sh           本脚本（单文件，可直接拷到 /root/bin/）
README-set-proxy.md    本文档
```

撤销本项目相关的其它命令（可选）：

```bash
bash /root/bin/set-proxy.sh show     # 确认「旧 proxy.sh 残留」那一行是「无」
rm -f  /root/.sh-tx-proxy            # 旧软链
rm -rf /opt/github/sh-tx-proxy       # 旧仓库
```