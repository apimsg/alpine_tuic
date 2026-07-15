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

📌 管理命令
# 🚀 启动服务（拉起守护脚本，它会自动启动 tuic）
pkill -f tuic-guard.sh; nohup /usr/local/bin/tuic-guard.sh > /dev/null 2>&1 &

# 🛑 停止服务（杀掉守护脚本，tuic 也会随之停止）
pkill -f tuic-guard.sh

# 🔄 重启服务（先杀后启，一步到位）
pkill -f tuic-guard.sh; nohup /usr/local/bin/tuic-guard.sh > /dev/null 2>&1 &

# 🔍 查看真实运行状态（检查进程是否存在）
ps aux | grep tuic

# ⚙️ 查看配置文件
cat /etc/tuic/config.json

# 📜 查看实时日志
tail -f /var/log/tuic.log

❌ 卸载命令
先停止服务（pkill -f tuic-guard.sh）再卸载

重新输入一键命令可以修改端口，可以卸载tuic


























