# sh-tx-proxy

在终端里手动切换 HTTP 代理的小脚本。

`proxy.sh` 提供四个命令：`p-sh` 切到上海代理，`p-tx` 切到 TX 代理，`poff` 关闭代理，`pst` 查看当前代理状态。

## 代理地址

| 命令 | 代理地址 | 说明 |
| --- | --- | --- |
| `p-sh` | `http://10.10.2.14:7890` | 上海 |
| `p-tx` | `http://10.100.36.162:7890` | TX |

两个地址都硬编码在 `proxy.sh` 顶部的 `PROXY_SH` / `PROXY_TX` 变量里，换地址直接改这两行即可。

## 安装

把脚本放到任意位置，然后在你 shell 的启动文件里 source 它：

```bash
git clone https://github.com/moyu588/sh-tx-proxy.git ~/.sh-tx-proxy
echo 'source ~/.sh-tx-proxy/proxy.sh' >> ~/.bashrc
```

zsh 用户写进 `~/.zshrc`。

## 使用

**脚本必须用 `source` 加载**，因为它靠 `export` 和 `alias` 修改当前 shell 的环境。直接 `./proxy.sh` 执行会在子进程里改完就退出，当前终端不受影响。

```bash
source proxy.sh

p-sh          # 代理: http://10.10.2.14:7890
p-tx          # 代理: http://10.100.36.162:7890
pst           # 查看当前代理环境变量
poff          # 代理已关闭
```

切换会同时写入大小写两套变量：`http_proxy` / `https_proxy` / `all_proxy` 及对应的 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`，兼顾只认小写（curl、wget）和只认大写（部分 Go / Java 程序）的工具。

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `p-sh` | 切换到上海代理 |
| `p-tx` | 切换到 TX 代理 |
| `poff` | 清空所有代理环境变量 |
| `pst` | 列出当前生效的代理环境变量 |

## 直连白名单

无论走哪个代理，`no_proxy` / `NO_PROXY` 始终包含以下网段，内网访问不受影响：

```
localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12
```

需要改动就编辑 `proxy.sh` 里的 `NO_PROXY_LIST`。

## 注意事项

- **只对当前 shell 生效。** 每个新开的终端窗口都需要重新 `source`（写进启动文件即可自动加载），已启动的其他程序不会受影响。
- **CIDR 写法并非所有工具都支持。** `10.0.0.0/8` 这类网段写法，curl、Go 程序能正确识别，但 Python `requests` 等只做后缀匹配的工具看不懂，可能需要改成逐个 IP 或用后缀域名。
- 如果公司还有别的代理环境，照抄 `PROXY_SH` / `alias p-sh` 的模式加一组即可。
