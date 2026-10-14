# set-proxy.sh —— 把代理写进各工具自己的配置文件

单文件、无依赖。运行一次后，新开的终端、脚本、工具自动带代理，**不需要任何 source、shell 函数或常驻脚本**。

安装（用软链指向仓库，别拷副本，否则会跟仓库漂移）：

```bash
ln -sf /opt/github/sh-tx-proxy/set-proxy.sh /usr/local/bin/set-proxy.sh
set-proxy.sh tx      # 配 TX 代理（默认不碰 /etc、不需要 root）
set-proxy.sh show    # 自检
```

`/usr/local/bin` 在 PATH 里，所以能直接敲 `set-proxy.sh`。以后更新只要 `cd /opt/github/sh-tx-proxy && git pull`，软链自动指向新内容。

---

## 一、为什么写 4 个 rc 文件（`.bashrc`/`.zshrc` 不够）

只写 `.bashrc` + `.zshrc` 会漏会话，实测如下：

| 会话类型 | 只写 .bashrc/.zshrc | 本脚本（4 个 rc） | 靠哪个文件 |
| --- | --- | --- | --- |
| `bash -ic` 交互 bash | ✅ | ✅ | `~/.bashrc` |
| `bash -lc` 登录 bash | ❌ | ✅ | `~/.profile` |
| `bash -c` 非交互 bash / 脚本 | ❌ | ❌ | 只能靠 `--env`（见下） |
| `zsh -ic` 交互 zsh | ✅ | ✅ | `~/.zshrc` |
| `zsh -c` 非交互 zsh / 脚本 | ❌ | ✅ | `~/.zshenv` |
| `zsh -lc` 登录 zsh | ❌ | ✅ | `~/.zshenv` |
| `sh -lc` 登录 sh | ❌ | ✅ | `~/.profile` |

两个坑的成因（都实测过）：

1. **`bash -c` 读不到末尾追加的块**：Kali 的 `~/.bashrc` 第 6-8 行是 `case $- in *i*) ;; *) return;; esac`，非交互直接 `return`；把 `BASH_ENV` 指向 `~/.bashrc` 也被同一行挡住。这类只能靠 `--env`。
2. **`zsh -c`/`zsh -lc` 读不到 `.zshrc`**：zsh 的 `.zshenv` 每次调用都读、`.zshrc` 只有交互式才读。所以补了 `.zshenv`。

脚本写这 4 个 rc：`.bashrc`、`.zshrc`、`.zshenv`、`.profile`。**特意不写 `~/.bash_profile`** —— bash 登录只读「`.bash_profile` → `.bash_login` → `.profile`」里第一个存在的，凭空建 `.bash_profile` 会遮蔽 `.profile`，把 PATH 等一起搞丢。

---

## 二、写到哪里

**默认（不带开关）** —— 只写这些，**不碰 `/etc`、不需要 root**：

| 位置 | 管什么 |
| --- | --- |
| `~/.bashrc` `~/.zshrc` `~/.zshenv` `~/.profile` | 各类 shell 会话（见上表） |
| `~/.gitconfig` → `http.proxy` / `https.proxy` | git（其优先级高于环境变量，故任何 shell 都一致） |
| `~/.npmrc` → `proxy` / `https-proxy` / `noproxy` | npm / npx / node-gyp（npm **不读** `http_proxy`，必须写这里） |
| `~/.curlrc` → `proxy` / `noproxy` | curl |
| `~/.wgetrc` → `use_proxy` / `http_proxy` / `no_proxy` | wget |
| `~/.config/pip/pip.conf` → `global.proxy` / `global.noproxy` | pip（已配国内镜像的机器非必需） |

**可选开关**（不点名就不生效）：

| 开关 | 做什么 | 用途 |
| --- | --- | --- |
| `--env` | 写 `/etc/environment`（需 root） | 给**只认环境变量**的程序：`python requests`/`urllib` 没有配置文件入口，cron、`su -`、新 ssh 登录也靠它。经 PAM(`pam_env`) 注入，**只对之后新登录的会话生效** |
| `--go` | `go env -w GOPROXY=https://goproxy.cn,direct` | `go get` 不用翻墙（写进 `~/.config/go/env`） |
| `--everything` | = `--env` + `--go` | |
| `--sweep` | 清掉 rc 里残留的 `source .../proxy.sh` 行 | 仅从旧版 `proxy.sh` 迁移的机器需要 |

`no_proxy` 全处统一为 `localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12`。

---

## 三、用法

```bash
set-proxy.sh tx                  # TX 10.100.36.162:7890
set-proxy.sh sh                  # 上海 10.10.2.14:7890
set-proxy.sh http://1.2.3.4:7890 # 任意地址
set-proxy.sh show                # 自检
set-proxy.sh off                 # 撤销（须带上当初用过的同样开关）
set-proxy.sh tx --everything     # 再加 /etc/environment 与 GOPROXY（需 root）
```

- 改默认值：环境变量 `PROXY_SH` / `PROXY_TX` / `NO_PROXY_LIST` / `GOPROXY_MIRROR`。
- 演练（不碰真系统）：`SET_PROXY_HOME=/tmp/h SET_PROXY_ETC_DIR=/tmp/e set-proxy.sh tx --everything`
- **撤销要带同样的开关**：`--env`/`--go` 写出去的，`off` 时也要带对应开关才会被清掉，避免误删你本没让脚本碰的东西。

---

## 四、安全性

| 机制 | 说明 |
| --- | --- |
| 标记块 | 内容都包在 `# ---- proxy (managed by set-proxy.sh) ----` … `# ---- proxy end ----` 之间，重复执行只替换该块、**不堆叠** |
| 备份 | 首次改动某文件留 `<文件>.bak-set-proxy` |
| 逐字节还原 | `off` 后 `.bashrc`/`.zshrc`/`.profile`/`/etc/environment` 与改动前逐字节一致（`cmp` 验证） |
| 零残留 | 脚本新建的 `.zshenv`/`.curlrc`/`.wgetrc`/`pip.conf` 等在 `off` 后连空壳、空目录一并删除 |
| 拒绝危险情况 | `HOME` 为空或不可写直接退出，不会误写 `/.bashrc` |
| 不越界 | 不碰 `~/.bash_profile`/`~/.bash_login`；不覆盖别人的配置（`/etc/environment` 其它键、`.npmrc` 已有键等原样保留） |

---

## 五、自检

```bash
set-proxy.sh show
```

输出两部分：**每一处当前配置**（rc 四文件有无块及取值、git/npm/curl/wget/pip、GOPROXY、`/etc/environment`、当前会话 env、旧 `proxy.sh` 残留）与**端到端自检**（curl、python requests、git ls-remote、内网直连）。`python` 那行只在 `--env` 存在时注入变量实测，否则说明"它只认环境变量，故跳过"。

---

## 六、常见问题

**改完当前终端怎么没代理？** rc 只对新开 shell 生效。当前终端 `source ~/.zshrc`（或 `~/.bashrc`）；已运行的进程/服务要重启。

**`bash -c` / 脚本里还是没代理？** `.bashrc` 对非交互提前 return，rc 层面无解 → 加 `--env`（需重新登录），或脚本里显式 `export`。

**cron / systemd 服务？** cron 走 PAM，`--env` 能覆盖（新登录后生效）。systemd unit 不读 shell 配置，在 unit 里写 `Environment="https_proxy=http://10.100.36.162:7890"`。

**`sudo` 之后没了？** sudo 默认清空环境变量。需要就 `Defaults env_keep += "http_proxy https_proxy no_proxy"`；但 git/npm/curl 读各自配置文件，多数不受影响。

**python 为什么必须 `--env`？** `requests`/`urllib` 只读环境变量，无配置文件入口 → `--env` 或代码里显式传 `proxies=`。

**换办公地点？** `set-proxy.sh sh`（或 `tx`）一条命令全机改；用过 `--env` 就带上开关并重新登录。

**代理那台机器（Windows clash）睡了/关机了？** 配置仍指向该地址，表现为外网命令慢超时而非快速失败。`show` 的端到端自检能立刻看出；也可让 git 快速失败：`git config --global http.lowSpeedLimit 1000; git config --global http.lowSpeedTime 10`。