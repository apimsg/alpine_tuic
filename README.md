# Alpine TUIC 一键安装脚本

本项目提供一个适用于 **Alpine Linux** 的 TUIC v5 一键安装脚本，自动完成依赖安装、证书生成/申请、配置文件生成、OpenRC 服务创建，并输出链接。

---

## 🚀 一键安装

复制并运行以下命令即可安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/apimsg/alpine_tuic/main/tuic-apline.sh)
```

⚙️ 功能特性
自动安装依赖（wget、curl、openssl、openrc 等）

支持自签证书 / ACME 证书

自动生成 UUID 和密码

自动生成配置文件 /etc/tuic/config.json

自动创建 OpenRC 服务 /etc/init.d/tuic

自动输出订阅链接（tuic://... 格式）

支持 IPv4 / IPv6

对于IPv6小鸡请选择IPv6链接

将零散的管理命令整合为“一键命令”是提升运维效率的最佳实践。基于我们最终完美版的脚本，我为您设计了以下几种一键管理方案：
方案一：使用脚本内置菜单（最推荐，最安全）
脚本本身已经包含了完整的交互式菜单，您只需要记住一条命令：
sh tuic.sh
执行后，脚本会自动检测环境并弹出菜单，您只需输入 1 修改端口、2 卸载、3 查看节点或 4 退出。
方案二：非交互式一键快捷命令（适合写备忘录或快捷别名）
如果您希望直接通过一行命令完成特定操作，而不想进入菜单，可以使用以下基于 PID 锁文件的安全命令：
🚀 一键启动服务
setsid /usr/local/bin/tuic-guard.sh </dev/null >/dev/null 2>&1 & echo $! > /var/run/tuic-guard.pid && echo "✅ 服务已启动"
🛑 一键停止服务
kill $(cat /var/run/tuic-guard.pid) 2>/dev/null; kill $(cat /var/run/tuic-server.pid) 2>/dev/null; rm -f /var/run/tuic-guard.pid /var/run/tuic-server.pid && echo "🛑 服务已停止"
🔄 一键重启服务
kill $(cat /var/run/tuic-guard.pid) 2>/dev/null; kill $(cat /var/run/tuic-server.pid) 2>/dev/null; rm -f /var/run/tuic-guard.pid /var/run/tuic-server.pid; setsid /usr/local/bin/tuic-guard.sh </dev/null >/dev/null 2>&1 & echo $! > /var/run/tuic-guard.pid && echo "🔄 服务已重启"
📜 一键查看实时日志
tail -f /tmp/tuic.log
🔍 一键查看运行状态
ps aux | grep -E "tuic-guard|tuic -c" | grep -v grep
⚙️ 一键查看配置文件
cat /etc/tuic/config.json
