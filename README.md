# Alpine TUIC 一键安装脚本

本项目提供一个适用于 **Alpine Linux（OpenRC）** 的 TUIC v5 一键安装 / 管理脚本，同时兼容 systemd 发行版。
自动完成依赖安装、证书生成、配置文件生成、服务自启，并内置 **OOM 自动重启** 守护层：

> 容器内存上限由宿主机固定、容器内无法改大时，TUIC 在高负载下会被内核 OOM killer 杀掉。
> 本脚本让 tuic 的 `oom_score_adj=1000`（OOM 时优先杀 tuic，**不会误杀 sshd**），
> 守护进程会在 **1~2 秒内自动重启** 并恢复监听，客户端重连即可，不需要人工介入。

---

## ✨ 特性

- 自动安装依赖（wget、curl、openssl、openrc、jq 等）
- 支持自签证书 / 自定义证书（`.crt` + `.key`）
- 自动生成 UUID、密码、配置文件 `/etc/tuic/config.json`
- **OOM 自适应守护**：tuic 被杀后 1~2 秒自动重启；退避 1→2→4→8→10 秒，健康运行 60 秒后重置为 1 秒
- **三层自启**：进程守护 + OpenRC 服务（`/etc/init.d/tuic`，已加入 default runlevel）+ cron 看门狗
- 守护进程本身被 `kill -9` / OOM 杀掉时，cron 看门狗 1 分钟内自动恢复
- 日志 5 MiB 滚动（保留最后 1 MiB），不会出现截断空洞
- 自动输出节点链接（`tuic://...`），并生成 v2rayN / Clash Meta 客户端配置
- 支持 IPv4 / IPv6（IPv6 小鸡请选择 IPv6 链接）
- 交互菜单 + 非交互命令两种用法，可批量部署

---

## 🚀 一键安装

> Alpine 默认没有 bash，请用 `sh` 执行（不要用 `bash <(curl ...)`）。

```sh
wget -qO /tmp/tuic-apline.sh https://raw.githubusercontent.com/apimsg/alpine_tuic/main/tuic-apline.sh
sh /tmp/tuic-apline.sh
```

没有安装过 TUIC 的机器：直接进入安装流程（提示端口 / 证书 / 拥塞算法）。

非交互安装（使用默认值：随机端口、自签证书、bbr）：

```sh
sh /tmp/tuic-apline.sh install
```

也可用环境变量跳过交互：

```sh
TUIC_PORT=443 TUIC_CC=bbr TUIC_SNI=www.bing.com sh /tmp/tuic-apline.sh install
# 使用已有证书：
# TUIC_CERT=/path/cert.pem TUIC_KEY=/path/key.pem TUIC_SNI=www.example.com sh /tmp/tuic-apline.sh install
```

---

## 🔧 已装旧版？重跑一次即自动修复

旧版脚本的守护层有问题（`pgrep -x tuic` 永远匹配不到、没有开机自启、日志被截断）。
**把新脚本拷到机器上重新运行一次即可，只升级守护层，保留现有配置、证书和节点信息**：

```sh
sh /tmp/tuic-apline.sh          # 检测到旧守护层 → 自动修复；已是新版 → 进入管理菜单
sh /tmp/tuic-apline.sh auto     # 非交互模式：已安装则修复，未安装则安装（适合批量部署）
```

批量部署到多台机器：

```sh
scp tuic-apline.sh root@<新机器>:/root/
ssh root@<新机器> 'sh /root/tuic-apline.sh auto'
```

---

## 📋 日常管理命令

| 操作 | 脚本命令 | 等价 OpenRC 命令 |
|---|---|---|
| 查看状态 | `sh tuic-apline.sh status` | `rc-service tuic status` |
| 启动 | `sh tuic-apline.sh start` | `rc-service tuic start` |
| 停止 | `sh tuic-apline.sh stop` | `rc-service tuic stop` |
| 重启 | `sh tuic-apline.sh restart` | `rc-service tuic restart` |
| 查看节点链接 | `sh tuic-apline.sh links` | — |
| 查看最近日志 | `sh tuic-apline.sh logs` | — |
| 修复/升级守护层 | `sh tuic-apline.sh upgrade` | — |
| 卸载 | `sh tuic-apline.sh uninstall` | — |

> 不要再用旧教程里的 `setsid ... & echo $! > pidfile`、`kill $(cat ...pid)` 一类命令：
> `$!` 记的是 `setsid` 的 PID，杀不掉真正的守护进程。统一用上面的 `rc-service` / 脚本命令。

---

## 🧭 交互菜单

直接运行 `sh tuic-apline.sh`（已安装时）：

```
1) 查看节点链接
2) 查看运行状态
3) 重启服务
4) 修改端口
5) 修复/升级守护层（OOM 自动重启）
6) 查看最近日志
7) 卸载 TUIC
8) 退出
```

---

## 🧠 关于 OOM 自动重启（重要）

1. 容器内存上限是**宿主机设定的**，容器内改不了，也**不要**去改；本脚本不会尝试改内存上限。
2. TUIC 的 RSS 会随连接/流量增长（新启动约 6 MiB，跑久可到 40 MiB 左右），
   所以在小内存容器里 **OOM 迟早会发生，这是正常现象，不是故障**。
3. 脚本把 tuic 的 `oom_score_adj` 设为 **1000**：内核 OOM killer 优先杀 tuic，
   `sshd`、守护进程、crond 不受影响。
4. OOM 杀掉 tuic 后，守护进程 **1~2 秒** 内拉起新进程并恢复监听；
   连续被 OOM 时按 1→2→4→8→10 秒退避，避免重启风暴。
5. 守护进程本身被 `kill -9` 时，cron 看门狗会在 1 分钟内恢复整个服务。
6. 容器重启后，OpenRC 服务会自动拉起 TUIC。

### 压力测试结果（真实 cgroup OOM，64 MiB 上限，3 轮）

| 轮次 | 触发点 | oom_kill 计数 | 被 OOM 杀的进程 | 恢复耗时 | 恢复后监听 |
|---|---|---|---|---|---|
| 1 | tmpfs 压到 54 MiB | 8 → 9 | tuic | 1 秒 | 正常 |
| 2 | tmpfs 压到 54 MiB | 9 → 10 | tuic | 2 秒 | 正常 |
| 3 | tmpfs 压到 54 MiB | 10 → 11 | tuic | 4 秒 | 正常 |

三轮 OOM 中守护进程 PID 始终不变，`sshd` / `crond` 均未被误杀。

### 降低 OOM 频率的建议

- 少在容器里开 SSH 会话、不要跑大命令（每个 sshd 会话本身要占几 MiB）。
- 流量很大且 OOM 过于频繁时，可考虑换更省内存的代理实现，或申请更大的容器配额。

---

## 📁 文件与路径

| 用途 | 路径 |
|---|---|
| TUIC 二进制 | `/usr/local/bin/tuic` |
| 守护脚本 | `/usr/local/bin/tuic-guard.sh` |
| cron 看门狗 | `/usr/local/bin/tuic-watchdog.sh` |
| OpenRC 服务 | `/etc/init.d/tuic`（systemd 为 `/etc/systemd/system/tuic.service`） |
| 配置 | `/etc/tuic/config.json` |
| 证书 / 私钥 | `/etc/tuic/cert.pem`、`/etc/tuic/key.pem` |
| 节点链接 | `/etc/tuic/tuic-links.txt`（软链 `~/tuic-links.txt`） |
| 客户端配置 | `/etc/tuic/v2rayn-tuic.json`、`/etc/tuic/clash-tuic.yaml` |
| 业务日志 | `/var/log/tuic.log` |
| 守护/重启日志 | `/var/log/tuic-guard.log` |

---

## 🔍 日志与排查

```sh
sh tuic-apline.sh status          # 状态 + 内存上限 + OOM 计数
tail -f /var/log/tuic.log         # 业务日志
tail -f /var/log/tuic-guard.log   # 每次退出的 rc / 运行时长 / 重启延迟 / 看门狗动作
cat /sys/fs/cgroup/memory.events  # oom_kill 增长说明正在被 OOM（正常现象，会自动重启）
```

- `rc=137` 表示进程被 SIGKILL（通常就是 OOM killer）。
- 若反复重启且每次运行时间都很短，先确认是不是内存压力持续存在；
  持续压力解除后，守护进程会自动恢复到正常状态。
- 修改端口：`sh tuic-apline.sh` → 菜单 4，或直接改 `/etc/tuic/config.json` 后 `rc-service tuic restart`。

---

## 🗑 卸载

```sh
sh tuic-apline.sh uninstall
```

会停止服务、删除 OpenRC 服务 / 定时任务 / 二进制 / 配置与证书（crond 保留，其它定时任务不受影响）。

---

## 🖥 兼容性

- **Alpine Linux（OpenRC）**：完整支持（推荐）
- **systemd 发行版**（Debian/Ubuntu/CentOS 等）：自动生成 `tuic.service`（`Restart=always`），
  守护层逻辑相同
- 纯 Docker 容器（无 init）：额外生成 `/start.sh`，可用
  `docker run -d --restart=always --entrypoint /bin/sh <镜像> /start.sh` 启动
