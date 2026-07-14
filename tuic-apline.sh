#!/bin/sh
set -e

TUIC_BIN="/usr/local/bin/tuic"
GUARD_BIN="/usr/local/bin/tuic-guard.sh"
CERT_DIR="/etc/tuic"
CONFIG_FILE="$CERT_DIR/config.json"

# ===== 管理菜单 =====
if [ -x "$TUIC_BIN" ]; then
  echo "---------------------------------------"
  echo " 检测到已安装 TUIC v5"
  echo "---------------------------------------"
  echo "请选择操作:"
  echo "1) 修改端口"
  echo "2) 卸载 TUIC"
  echo "3) 查看节点信息"
  echo "4) 退出"
  read -p "请输入选项 [1-4]: " choice

  case "$choice" in
    1)
      read -p "请输入新的端口号: " NEW_PORT
      [ -z "$NEW_PORT" ] && echo "❌ 端口不能为空" && exit 1
      sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" "$CONFIG_FILE"
      pkill -f tuic-guard.sh && nohup $GUARD_BIN > /dev/null 2>&1 &
      echo "✅ 端口已修改为 $NEW_PORT 并已重启服务"
      exit 0
      ;;
    2)
      echo "正在卸载 TUIC..."
      pkill -f tuic-guard.sh || true
      rm -f "$TUIC_BIN" "$GUARD_BIN"
      rm -rf "$CERT_DIR"
      sed -i '/tuic-guard.sh/d' /etc/rc.local || true
      echo "✅ TUIC 已卸载完成"
      exit 0
      ;;
    3)
      cat "$CERT_DIR/tuic-links.txt"
      exit 0
      ;;
    4) echo "已退出"; exit 0 ;;
    *) echo "无效选项"; exit 1 ;;
  esac
fi

# ===== 安装流程 =====
echo "---------------------------------------"
echo " TUIC v5 全系统通用安装脚本 "
echo "---------------------------------------"

# --- 智能检测包管理器 ---
if command -v apk > /dev/null 2>&1; then
    echo "检测到 Alpine Linux (apk)，正在安装依赖..."
    apk add --no-cache wget curl openssl openrc lsof coreutils jq file >/dev/null
    apk add --no-cache aria2 >/dev/null || true
elif command -v dnf > /dev/null 2>&1; then
    echo "检测到 dnf 包管理器，正在安装依赖..."
    dnf install -y wget curl openssl lsof coreutils jq file aria2
elif command -v yum > /dev/null 2>&1; then
    echo "检测到 yum 包管理器，正在安装依赖..."
    yum install -y wget curl openssl lsof coreutils jq file aria2
elif command -v apt-get > /dev/null 2>&1; then
    echo "检测到 Debian/Ubuntu (apt)，正在安装依赖..."
    apt-get update >/dev/null
    apt-get install -y wget curl openssl lsof coreutils jq file aria2
else
    echo "❌ 未找到支持的包管理器 (apk/yum/dnf/apt)。"
    exit 1
fi
# --- 检测结束 ---

# ===== 下载 TUIC 二进制 =====
TAG=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)
[ -z "$TAG" ] || [ "$TAG" = "null" ] && TAG="tuic-server-1.0.0"
VERSION=${TAG#tuic-server-}

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) FILENAME="tuic-server-${VERSION}-x86_64-unknown-linux-musl" ;;
    aarch64) FILENAME="tuic-server-${VERSION}-aarch64-unknown-linux-musl" ;;
    armv7l) FILENAME="tuic-server-${VERSION}-armv7-unknown-linux-musleabihf" ;;
    *) echo "❌ 不支持的 CPU 架构: $ARCH"; exit 1 ;;
esac

URLS="
https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
https://mirror.ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
"

SUCCESS=0
for url in $URLS; do
  echo "尝试下载: $url"
  rm -f /tmp/tuic_temp*
  wget --timeout=30 --tries=3 -O /tmp/tuic_temp "$url" || continue
  FILE_TYPE=$(file /tmp/tuic_temp)
  if echo "$FILE_TYPE" | grep -q "ELF"; then
    mv /tmp/tuic_temp $TUIC_BIN
    chmod +x $TUIC_BIN
    SUCCESS=1
    break
  fi
done
[ $SUCCESS -eq 0 ] && echo "❌ 下载失败" && exit 1

# ===== 证书处理 =====
mkdir -p $CERT_DIR
read -p "请输入证书 (.crt) 文件绝对路径 (回车则生成自签证书): " CERT_PATH
if [ -z "$CERT_PATH" ]; then
  read -p "请输入伪装域名 (默认 www.bing.com): " FAKE_DOMAIN
  [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.bing.com"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout $CERT_DIR/key.pem -out $CERT_DIR/cert.pem -days 825 \
    -subj "/CN=$FAKE_DOMAIN"
  CERT_PATH="$CERT_DIR/cert.pem"
  KEY_PATH="$CERT_DIR/key.pem"
else
  read -p "请输入私钥 (.key) 文件绝对路径: " KEY_PATH
  read -p "请输入证书域名 (SNI): " FAKE_DOMAIN
fi

# ===== 生成配置 =====
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -base64 16)
[ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.bing.com"

read -p "请输入 TUIC 端口 (默认随机): " PORT
[ -z "$PORT" ] && PORT=$(shuf -i 20000-60000 -n 1)

echo "请选择拥塞控制算法:"
echo "1) bbr (推荐: 丢包多/跨境线路)"
echo "2) cubic (推荐: 稳定小鸡/低丢包环境)"
read -p "请输入选项 [1-2] (默认 1): " CC_CHOICE
case "$CC_CHOICE" in
  2) CC_ALGO="cubic" ;;
  *) CC_ALGO="bbr" ;;
esac
echo "已选择拥塞算法: $CC_ALGO"

cat > $CONFIG_FILE <<EOF
{
  "server": "[::]:$PORT",
  "users": {
    "$UUID": "$PASS"
  },
  "certificate": "$CERT_PATH",
  "private_key": "$KEY_PATH",
  "alpn": ["h3"],
  "congestion_control": "$CC_ALGO"
}
EOF

# ===== 创建并配置 tuic-guard.sh 守护脚本 =====
echo "正在配置守护脚本..."
cat <<EOF > $GUARD_BIN
#!/bin/bash
while true; do
    if ! pgrep -x "tuic" > /dev/null; then
        $TUIC_BIN -c $CONFIG_FILE > /var/log/tuic.log 2>&1 &
    fi
    sleep 10
done
EOF
chmod +x $GUARD_BIN

# 配置开机自启，防止重复添加
if ! grep -q "tuic-guard.sh" /etc/rc.local; then
    echo "nohup $GUARD_BIN > /dev/null 2>&1 &" >> /etc/rc.local
fi
chmod +x /etc/rc.local

# 立即启动守护脚本
nohup $GUARD_BIN > /dev/null 2>&1 &

# ---------------- 输出链接 ----------------
IPV4=$(curl -s ipv4.icanhazip.com || true)
IPV6=$(curl -s ipv6.icanhazip.com || true)
ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
ENC_SNI=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)

LINK_FILE="$CERT_DIR/tuic-links.txt"
> "$LINK_FILE"

if [ -n "$IPV6" ]; then
  COUNTRY6=$(curl -s "http://ip-api.com/line/${IPV6}?fields=countryCode" || true)
  [ -z "$COUNTRY6" ] && COUNTRY6="XX"
  LINK6="tuic://$UUID:$ENC_PASS@[$IPV6]:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY6}-IPv6-$CC_ALGO"
  echo "$LINK6" >> "$LINK_FILE"
  echo "IPv6 节点: $LINK6"
fi

if [ -n "$IPV4" ]; then
  COUNTRY4=$(curl -s "http://ip-api.com/line/${IPV4}?fields=countryCode" || true)
  [ -z "$COUNTRY4" ] && COUNTRY4="XX"
  LINK4="tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY4}-IPv4-$CC_ALGO"
  echo "$LINK4" >> "$LINK_FILE"
  echo "IPv4 节点: $LINK4"
fi

ln -sf "$LINK_FILE" /root/tuic-links.txt
echo "✅ 所有链接已保存到: $LINK_FILE"
echo "快捷访问: ~/tuic-links.txt"

# ===== 生成 v2rayN 节点配置 =====
V2RAYN_FILE="$CERT_DIR/v2rayn-tuic.json"
cat > $V2RAYN_FILE <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-$CC_ALGO",
  "settings": {
    "server": "${IPV4:-$IPV6}",
    "server_port": $PORT,
    "uuid": "$UUID",
    "password": "$PASS",
    "congestion_control": "$CC_ALGO",
    "alpn": ["h3"],
    "sni": "$FAKE_DOMAIN",
    "udp_relay_mode": "native",
    "disable_sni": false,
    "reduce_rtt": true
  }
}
EOF

# ===== 生成 Clash Meta 配置 =====
CLASH_FILE="$CERT_DIR/clash-tuic.yaml"
cat > $CLASH_FILE <<EOF
proxies:
  - name: "TUIC-${CC_ALGO}"
    type: tuic
    server: ${IPV4:-$IPV6}
    port: $PORT
    uuid: "$UUID"
    password: "$PASS"
    alpn: ["h3"]
    sni: "$FAKE_DOMAIN"
    congestion_control: $CC_ALGO
    udp_relay_mode: native
    skip-cert-verify: true
    disable_sni: false
    reduce_rtt: true
EOF

# ===== 打印配置文件内容 =====
echo "---------------------------------------"
echo "✅ v2rayN 配置已生成: $V2RAYN_FILE"
echo "---------------------------------------"
cat "$V2RAYN_FILE"
echo ""
echo "---------------------------------------"
echo "✅ Clash Meta 配置已生成: $CLASH_FILE"
echo "---------------------------------------"
cat "$CLASH_FILE"
