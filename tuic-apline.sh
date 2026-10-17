#!/bin/sh
# ==============================================================
#  TUIC v5 一键安装 / 管理脚本
#  - 优先适配 Alpine Linux（OpenRC），同时兼容 systemd 发行版
#  - OOM 自适应：容器内存上限由宿主固定时无法改大，
#    本脚本保证 OOM killer 杀掉 tuic 后 1~2 秒自动重启，
#    且 tuic 的 oom_score_adj=1000，不会误杀 sshd / 守护进程
#  - 三层守护：进程守护 + 服务自启（OpenRC/systemd）+ cron 看门狗
#
#  用法:
#    sh tuic-apline.sh            交互菜单
#    sh tuic-apline.sh install    安装（有 TTY 时交互，否则用默认值）
#    sh tuic-apline.sh upgrade    只修复/升级守护层（保留配置与证书）
#    sh tuic-apline.sh status | start | stop | restart
#    sh tuic-apline.sh links | logs | uninstall
# ==============================================================

TUIC_BIN="/usr/local/bin/tuic"
GUARD_BIN="/usr/local/bin/tuic-guard.sh"
WATCHDOG_BIN="/usr/local/bin/tuic-watchdog.sh"
CERT_DIR="/etc/tuic"
CONFIG_FILE="$CERT_DIR/config.json"
META_FILE="$CERT_DIR/meta.env"
LINK_FILE="$CERT_DIR/tuic-links.txt"
GUARD_PIDFILE="/run/tuic-guard.pid"
TUIC_PIDFILE="/run/tuic-server.pid"
LOG_FILE="/var/log/tuic.log"
GUARD_LOG="/var/log/tuic-guard.log"
CRON_ROOT="/var/spool/cron/crontabs/root"
START_SH="/start.sh"
INIT="none"

info() { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# 字节 -> MiB（兼容 cgroup 的 "max"）
mb() {
  case "$1" in
    ''|max) echo "?" ;;
    *) echo $(( $1 / 1048576 )) ;;
  esac
}

require_root() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行本脚本"
}

detect_init() {
  if [ -x /sbin/openrc-run ] && command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
  else
    INIT="none"
  fi
}

in_container() {
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0
  if grep -qsE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi
  return 1
}

rand_port() {
  _n=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
  [ -z "$_n" ] && _n=12345
  echo $(( (_n % 40000) + 20000 ))
}

# ---------- 进程查找（不依赖 pgrep 的实现差异） ----------
# tuic 进程：comm 就是二进制名 "tuic"
tuic_pids() {
  for _d in /proc/[0-9]*; do
    _p=${_d#/proc/}
    [ "$_p" = "$$" ] && continue
    [ "$(cat "$_d/comm" 2>/dev/null)" = "tuic" ] && echo "$_p"
  done
}

# 守护进程：cmdline 里带 tuic-guard.sh（看门狗自身是 tuic-watchdog.sh，不会误匹配）
# 守护进程：精确匹配 argv（argv[0] 或 argv[1] 等于守护脚本路径），
# 避免误杀命令行里恰好包含该字符串的 shell（旧实现用 grep 子串匹配，踩过坑）
guard_pids() {
  for _d in /proc/[0-9]*; do
    _p=${_d#/proc/}
    [ "$_p" = "$$" ] && continue
    _a1=$(tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | sed -n 1p)
    _a2=$(tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | sed -n 2p)
    if [ "$_a1" = "$GUARD_BIN" ] || [ "$_a2" = "$GUARD_BIN" ]; then
      echo "$_p"
    fi
  done
}

kill_all_tuic() {
  for _p in $(tuic_pids); do
    kill -TERM "$_p" 2>/dev/null
  done
  sleep 1
  for _p in $(tuic_pids); do
    kill -KILL "$_p" 2>/dev/null
  done
}

kill_all_guards() {
  for _p in $(guard_pids); do
    kill -TERM "$_p" 2>/dev/null
  done
  sleep 1
  for _p in $(guard_pids); do
    kill -KILL "$_p" 2>/dev/null
  done
}

# ---------- 依赖安装 ----------
install_deps() {
  if command -v apk >/dev/null 2>&1; then
    info "检测到 Alpine Linux (apk)，安装依赖..."
    apk add --no-cache wget curl openssl openrc coreutils jq file procps >/dev/null 2>&1 || \
      apk add --no-cache wget curl openssl openrc coreutils jq file >/dev/null 2>&1 || \
      die "依赖安装失败"
    apk add --no-cache aria2 >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    info "检测到 dnf，安装依赖..."
    dnf install -y wget curl openssl jq file procps-ng >/dev/null 2>&1 || die "依赖安装失败"
  elif command -v yum >/dev/null 2>&1; then
    info "检测到 yum，安装依赖..."
    yum install -y wget curl openssl jq file procps-ng >/dev/null 2>&1 || die "依赖安装失败"
  elif command -v apt-get >/dev/null 2>&1; then
    info "检测到 apt，安装依赖..."
    apt-get update >/dev/null 2>&1
    apt-get install -y wget curl openssl jq file procps >/dev/null 2>&1 || die "依赖安装失败"
  else
    die "未找到支持的包管理器 (apk/yum/dnf/apt)"
  fi
}

# ---------- 下载 TUIC ----------
download_tuic() {
  info "正在获取 TUIC 最新版本..."
  TAG=$(curl -fsSL --max-time 10 https://api.github.com/repos/tuic-protocol/tuic/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  if [ -z "$TAG" ]; then
    TAG="tuic-server-1.0.0"
  fi
  VERSION=${TAG#tuic-server-}

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  FILENAME="tuic-server-${VERSION}-x86_64-unknown-linux-musl" ;;
    aarch64) FILENAME="tuic-server-${VERSION}-aarch64-unknown-linux-musl" ;;
    armv7l)  FILENAME="tuic-server-${VERSION}-armv7-unknown-linux-musleabihf" ;;
    *) die "不支持的 CPU 架构: $ARCH" ;;
  esac

  SUCCESS=0
  mkdir -p /usr/local/bin
  for _url in \
    "https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME" \
    "https://mirror.ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME" \
    "https://ghfast.top/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME"
  do
    info "尝试下载: $_url"
    rm -f /tmp/tuic_temp
    wget -q --timeout=30 --tries=2 -O /tmp/tuic_temp "$_url" 2>/dev/null || continue
    if file /tmp/tuic_temp 2>/dev/null | grep -q "ELF"; then
      mv /tmp/tuic_temp "$TUIC_BIN"
      chmod 0755 "$TUIC_BIN"
      SUCCESS=1
      break
    fi
  done
  [ "$SUCCESS" = "1" ] || die "TUIC 下载失败（可手动下载后放到 $TUIC_BIN）"
  info "TUIC 已就绪: $("$TUIC_BIN" --version 2>/dev/null | head -n 1 || echo "$TUIC_BIN")"
}

# ---------- 证书 ----------
gen_certificate() {
  mkdir -p "$CERT_DIR"
  CERT_PATH="${TUIC_CERT:-}"
  KEY_PATH="${TUIC_KEY:-}"
  FAKE_DOMAIN="${TUIC_SNI:-}"

  if [ -t 0 ] && [ -z "$CERT_PATH" ]; then
    printf '请输入证书 (.crt) 绝对路径（回车=生成自签证书）: '
    read CERT_PATH || CERT_PATH=""
  fi
  if [ -n "$CERT_PATH" ]; then
    [ -f "$CERT_PATH" ] || die "证书文件不存在: $CERT_PATH"
    if [ -t 0 ] && [ -z "$KEY_PATH" ]; then
      printf '请输入私钥 (.key) 绝对路径: '
      read KEY_PATH || KEY_PATH=""
    fi
    [ -f "$KEY_PATH" ] || die "私钥文件不存在: $KEY_PATH"
    [ -n "$FAKE_DOMAIN" ] || FAKE_DOMAIN="www.bing.com"
  else
    if [ -t 0 ] && [ -z "$FAKE_DOMAIN" ]; then
      printf '请输入伪装域名（默认 www.bing.com）: '
      read FAKE_DOMAIN || FAKE_DOMAIN=""
    fi
    [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.bing.com"
    info "正在生成自签证书（CN=$FAKE_DOMAIN）..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -days 825 \
      -subj "/CN=$FAKE_DOMAIN" >/dev/null 2>&1 || die "自签证书生成失败"
    chmod 600 "$CERT_DIR/key.pem"
    CERT_PATH="$CERT_DIR/cert.pem"
    KEY_PATH="$CERT_DIR/key.pem"
  fi
}

# ---------- 配置 ----------
gen_config() {
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  [ -z "$UUID" ] && UUID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  PASS=$(openssl rand -base64 16)

  PORT="${TUIC_PORT:-}"
  if [ -t 0 ] && [ -z "$PORT" ]; then
    printf '请输入 TUIC 端口（回车=随机 20000-60000）: '
    read PORT || PORT=""
  fi
  [ -z "$PORT" ] && PORT=$(rand_port)
  case "$PORT" in *[!0-9]*) die "端口必须是数字: $PORT" ;; esac
  if [ "$PORT" -lt 1 ] 2>/dev/null || [ "$PORT" -gt 65535 ] 2>/dev/null; then
    die "端口范围错误: $PORT"
  fi

  CC_ALGO="${TUIC_CC:-}"
  if [ -z "$CC_ALGO" ] && [ -t 0 ]; then
    printf '请选择拥塞控制 1) bbr(推荐) 2) cubic [默认 1]: '
    read _cc || _cc=""
    case "$_cc" in 2) CC_ALGO="cubic" ;; *) CC_ALGO="bbr" ;; esac
  fi
  [ -z "$CC_ALGO" ] && CC_ALGO="bbr"

  cat > "$CONFIG_FILE" <<EOF
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
  chmod 600 "$CONFIG_FILE"
  jq empty "$CONFIG_FILE" 2>/dev/null || die "生成的 config.json 不是合法 JSON"

  cat > "$META_FILE" <<EOF
TUIC_SNI="$FAKE_DOMAIN"
TUIC_CC="$CC_ALGO"
EOF
  chmod 600 "$META_FILE"
  info "配置已生成: $CONFIG_FILE（端口 $PORT / $CC_ALGO）"
}

# ---------- 守护脚本（核心：OOM 后自动重启） ----------
write_guard() {
  cat > "$GUARD_BIN" <<'GUARD_EOF'
#!/bin/sh
# TUIC v5 supervisor (OOM-resilient)
# - 任何原因退出（含 cgroup OOM killer 的 SIGKILL）都会在 1~2 秒内重启
# - tuic 的 oom_score_adj=1000：内存压力下内核优先杀 tuic，不会误杀 sshd
# - 退避 1s→10s，健康运行 >60s 后重置为 1s
# - 日志 5 MiB 滚动（保留最后 1 MiB），不会出现截断空洞
# - 启动时清理上一个守护进程留下的孤儿 tuic
TUIC=/usr/local/bin/tuic
CONF=/etc/tuic/config.json
LOG=/var/log/tuic.log
GUARD_LOG=/var/log/tuic-guard.log
PIDFILE=/run/tuic-guard.pid
CHILD_PIDFILE=/run/tuic-server.pid
MAXLOG=5242880
KEEP=1048576

# 单实例
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
    echo "[guard] already running (pid=$old), exit" >> "$GUARD_LOG"
    exit 1
  fi
fi
echo $$ > "$PIDFILE"

# 尽力把守护进程自己移出 OOM 候选（需要 CAP_SYS_RESOURCE，容器内通常无效，忽略即可）
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
trap '' HUP

tuic_pids() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    [ "$(cat "$d/comm" 2>/dev/null)" = "tuic" ] && echo "$p"
  done
}

# 清理孤儿（没有孤儿就不等待，加快启动）
stale=$(tuic_pids)
if [ -n "$stale" ]; then
  for p in $stale; do
    echo "[guard] killing stale tuic pid=$p" >> "$GUARD_LOG"
    kill -TERM "$p" 2>/dev/null
  done
  sleep 1
  for p in $(tuic_pids); do
    kill -KILL "$p" 2>/dev/null
  done
fi
rm -f "$CHILD_PIDFILE"

child=""
on_term() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
  n=0
  while [ -n "$child" ] && kill -0 "$child" 2>/dev/null && [ "$n" -lt 20 ]; do
    sleep 0.2
    n=$((n + 1))
  done
  [ -n "$child" ] && kill -KILL "$child" 2>/dev/null
  rm -f "$CHILD_PIDFILE" "$PIDFILE"
  exit 0
}
trap on_term TERM INT

rotate_log() {
  [ -f "$LOG" ] || return 0
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -le "$MAXLOG" ] && return 0
  tail -c "$KEEP" "$LOG" > "$LOG.rot" 2>/dev/null
  cat "$LOG.rot" > "$LOG" 2>/dev/null
  rm -f "$LOG.rot"
  echo "[guard] $(date -u +%Y-%m-%dT%H:%M:%SZ) log truncated to last ${KEEP}B (was ${sz}B)" >> "$GUARD_LOG"
}

backoff=1
while :; do
  rotate_log
  started=$(date +%s)
  "$TUIC" -c "$CONF" >> "$LOG" 2>&1 &
  child=$!
  echo "$child" > "$CHILD_PIDFILE"
  echo 1000 > "/proc/$child/oom_score_adj" 2>/dev/null
  wait "$child"
  rc=$?
  ran=$(( $(date +%s) - started ))
  child=""
  rm -f "$CHILD_PIDFILE"
  # 健康运行超过 60 秒：退避重置，下次崩溃 1 秒内恢复
  [ "$ran" -ge 60 ] && backoff=1
  delay=$backoff
  [ "$backoff" -lt 10 ] && backoff=$((backoff * 2))
  echo "[guard] $(date -u +%Y-%m-%dT%H:%M:%SZ) tuic exited rc=$rc after ${ran}s; restart in ${delay}s" >> "$GUARD_LOG"
  sleep "$delay"
done
GUARD_EOF
  chmod 0755 "$GUARD_BIN"
}

# ---------- cron 看门狗（守护进程本身被杀时兜底） ----------
write_watchdog() {
  cat > "$WATCHDOG_BIN" <<'WATCHDOG_EOF'
#!/bin/sh
# TUIC watchdog：由 cron 每分钟执行。
# 守护进程本身被 SIGKILL / OOM 干掉时，恢复整个服务。
GUARD=/usr/local/bin/tuic-guard.sh
GUARD_PIDFILE=/run/tuic-guard.pid
TUIC_PIDFILE=/run/tuic-server.pid
LOG=/var/log/tuic-guard.log

# 1) pidfile 有效即认为存活
if [ -f "$GUARD_PIDFILE" ]; then
  pid=$(cat "$GUARD_PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi
# 2) pidfile 丢失时兜底检查进程（精确匹配 argv，避免误判）
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ "$p" = "$$" ] && continue
  a1=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 1p)
  a2=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 2p)
  if [ "$a1" = "$GUARD" ] || [ "$a2" = "$GUARD" ]; then
    exit 0
  fi
done

echo "[watchdog] $(date -u +%Y-%m-%dT%H:%M:%SZ) supervisor is gone, restarting service" >> "$LOG"
if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/tuic ]; then
  rc-service tuic stop >/dev/null 2>&1
  rm -f /run/openrc/started/tuic "$GUARD_PIDFILE" "$TUIC_PIDFILE"
  rc-service tuic start >/dev/null 2>&1
elif command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/tuic.service ]; then
  systemctl restart tuic >/dev/null 2>&1
else
  setsid "$GUARD" </dev/null >/dev/null 2>&1 &
fi
WATCHDOG_EOF
  chmod 0755 "$WATCHDOG_BIN"
}

# ---------- OpenRC 服务 ----------
write_openrc_init() {
  cat > /etc/init.d/tuic <<'INIT_EOF'
#!/sbin/openrc-run
description="TUIC v5 proxy server"

command="/usr/local/bin/tuic-guard.sh"
command_args=""
command_background=true
pidfile="/run/tuic-guard.pid"
output_log="/var/log/tuic-guard.log"
error_log="/var/log/tuic-guard.log"

start_pre() {
	checkpath --file --mode 0644 /var/log/tuic.log
	checkpath --file --mode 0644 /var/log/tuic-guard.log
}

stop_post() {
	rm -f /run/tuic-guard.pid /run/tuic-server.pid
}
INIT_EOF
  chmod 0755 /etc/init.d/tuic
}

write_crond_init() {
  [ -x /etc/init.d/crond ] && return 0
  command -v crond >/dev/null 2>&1 || return 0
  cat > /etc/init.d/crond <<'CROND_EOF'
#!/sbin/openrc-run
description="Cron daemon"

command="/usr/sbin/crond"
command_args="-f -d 8"
command_background=true
pidfile="/run/crond.pid"
output_log="/var/log/crond.log"
error_log="/var/log/crond.log"
CROND_EOF
  chmod 0755 /etc/init.d/crond
}

# ---------- systemd 服务 ----------
write_systemd_unit() {
  cat > /etc/systemd/system/tuic.service <<'UNIT_EOF'
[Unit]
Description=TUIC v5 proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-guard.sh
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF
  chmod 0644 /etc/systemd/system/tuic.service
}

# ---------- 容器入口脚本（无 init 的纯 docker 环境兜底） ----------
write_start_sh() {
  cat > "$START_SH" <<'START_EOF'
#!/bin/sh
# 容器入口：启动 TUIC 守护进程并保持容器运行
# 用法: docker run -d --restart=always --entrypoint /bin/sh <镜像> /start.sh
chmod +x /usr/local/bin/tuic-guard.sh 2>/dev/null
if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/tuic ]; then
  rc-service tuic start 2>/dev/null
fi
if [ ! -s /run/tuic-guard.pid ]; then
  setsid /usr/local/bin/tuic-guard.sh </dev/null >/dev/null 2>&1 &
fi
exec tail -f /dev/null
START_EOF
  chmod 0755 "$START_SH"
}

# ---------- 服务启停 ----------
start_direct() {
  setsid "$GUARD_BIN" </dev/null >>"$GUARD_LOG" 2>&1 &
  i=0
  while [ "$i" -lt 25 ]; do
    [ -s "$GUARD_PIDFILE" ] && break
    sleep 0.2
    i=$((i + 1))
  done
}

start_service() {
  case "$INIT" in
    openrc)  rc-service tuic start 2>&1 ;;
    systemd) systemctl start tuic 2>&1 ;;
    *)       start_direct ;;
  esac
}

stop_service_any() {
  case "$INIT" in
    openrc)  rc-service tuic stop >/dev/null 2>&1 || true ;;
    systemd) systemctl stop tuic >/dev/null 2>&1 || true ;;
  esac
  kill_all_guards
  kill_all_tuic
  rm -f "$GUARD_PIDFILE" "$TUIC_PIDFILE" /var/run/tuic-guard.pid /var/run/tuic-server.pid
  rm -f /run/openrc/started/tuic 2>/dev/null
}

verify_started() {
  _i=0
  while [ "$_i" -lt 30 ]; do
    _t=$(cat "$TUIC_PIDFILE" 2>/dev/null)
    if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null; then
      info "TUIC 已启动（PID $_t）"
      return 0
    fi
    sleep 0.3
    _i=$((_i + 1))
  done
  warn "TUIC 启动似乎失败，请查看 $LOG_FILE / $GUARD_LOG"
  return 1
}

warn_memory_limit() {
  _lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  case "$_lim" in ''|max) return 0 ;; esac
  if [ "$_lim" -lt 268435456 ] 2>/dev/null; then
    warn "容器内存上限约 $(mb "$_lim") MiB，由宿主固定，容器内无法改大。"
    warn "高负载下 tuic 会被 OOM killer 杀掉，守护进程会在 1~2 秒内自动重启（属正常现象）。"
    warn "tuic 的 oom_score_adj=1000，OOM 时不会误杀 sshd。"
  fi
}

# 判断现有安装是否已经带有 OOM 自动重启守护层
supervision_ok() {
  [ -x "$GUARD_BIN" ] || return 1
  grep -qs "oom_score_adj" "$GUARD_BIN" || return 1
  grep -qs "backoff" "$GUARD_BIN" || return 1
  [ -x "$WATCHDOG_BIN" ] || return 1
  case "$INIT" in
    openrc)
      [ -f /etc/init.d/tuic ] || return 1
      grep -qs "tuic-watchdog" "$CRON_ROOT" 2>/dev/null || return 1
      ;;
    systemd)
      [ -f /etc/systemd/system/tuic.service ] || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# 旧版安装：重跑脚本即自动修复守护层（保留配置 / 证书 / 节点信息）
auto_repair() {
  info "======================================="
  info " 检测到 TUIC 已安装，但守护层不是 OOM 自动重启版本"
  info " 开始自动修复（保留现有配置与证书）..."
  info "======================================="
  do_upgrade
  info "---------------------------------------"
  info "修复完成：OOM killer 杀掉 tuic 后 1~2 秒自动重启"
  info "再次运行本脚本可进入管理菜单"
  info "---------------------------------------"
}

# ---------- 守护层安装（install 与 upgrade 共用） ----------
setup_supervision() {
  info "配置守护层..."
  mkdir -p /var/log
  touch "$LOG_FILE" "$GUARD_LOG"
  chmod 0644 "$LOG_FILE" "$GUARD_LOG" 2>/dev/null

  write_guard
  write_watchdog

  case "$INIT" in
    openrc)
      write_openrc_init
      rc-update add tuic default >/dev/null 2>&1 || warn "rc-update add tuic 失败（可稍后手动执行）"
      write_crond_init
      if [ -x /etc/init.d/crond ]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
      fi
      mkdir -p /var/spool/cron/crontabs
      touch "$CRON_ROOT" 2>/dev/null || true
      chmod 600 "$CRON_ROOT" 2>/dev/null || true
      if [ -f "$CRON_ROOT" ] && ! grep -q "tuic-watchdog" "$CRON_ROOT" 2>/dev/null; then
        echo "* * * * * $WATCHDOG_BIN" >> "$CRON_ROOT"
      fi
      ;;
    systemd)
      write_systemd_unit
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable tuic >/dev/null 2>&1 || warn "systemctl enable tuic 失败"
      ;;
    *)
      warn "未检测到 OpenRC/systemd，无法配置开机自启"
      ;;
  esac

  # 纯容器环境额外生成入口脚本（docker --restart=always 使用）
  if in_container; then
    write_start_sh
  fi

  # 清理旧版脚本可能留下的 rc.local 行
  if [ -f /etc/rc.local ]; then
    sed -i '/tuic-guard.sh/d' /etc/rc.local 2>/dev/null || true
  fi
}

# ---------- 节点链接 / 客户端配置 ----------
render_all() {
  _port=$1
  _uuid=$2
  _pass=$3
  _sni=$4
  _cc=$5

  _ip4=$(curl -s --max-time 10 ipv4.icanhazip.com 2>/dev/null || true)
  _ip6=$(curl -s --max-time 10 ipv6.icanhazip.com 2>/dev/null || true)
  _encpass=$(printf '%s' "$_pass" | jq -s -R -r @uri 2>/dev/null)
  _encsni=$(printf '%s' "$_sni" | jq -s -R -r @uri 2>/dev/null)
  _host="${_ip4:-$_ip6}"
  [ -z "$_host" ] && _host="<SERVER_IP>"

  : > "$LINK_FILE"
  if [ -n "$_ip6" ]; then
    _c6=$(curl -s --max-time 10 "http://ip-api.com/line/${_ip6}?fields=countryCode" 2>/dev/null || true)
    [ -z "$_c6" ] && _c6="XX"
    echo "tuic://$_uuid:$_encpass@[$_ip6]:$_port?sni=$_encsni&alpn=h3&congestion_control=$_cc#TUIC-${_c6}-IPv6-$_cc" >> "$LINK_FILE"
  fi
  if [ -n "$_ip4" ]; then
    _c4=$(curl -s --max-time 10 "http://ip-api.com/line/${_ip4}?fields=countryCode" 2>/dev/null || true)
    [ -z "$_c4" ] && _c4="XX"
    echo "tuic://$_uuid:$_encpass@$_ip4:$_port?sni=$_encsni&alpn=h3&congestion_control=$_cc#TUIC-${_c4}-IPv4-$_cc" >> "$LINK_FILE"
  fi
  ln -sf "$LINK_FILE" /root/tuic-links.txt

  if [ ! -s "$LINK_FILE" ]; then
    warn "无法自动获取公网 IP，请手动用服务器 IP 拼接节点链接"
    warn "配置中的 UUID / 密码 / 端口见 $CONFIG_FILE"
  fi

  cat > "$CERT_DIR/v2rayn-tuic.json" <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-$_cc",
  "settings": {
    "server": "$_host",
    "server_port": $_port,
    "uuid": "$_uuid",
    "password": "$_pass",
    "congestion_control": "$_cc",
    "alpn": ["h3"],
    "sni": "$_sni",
    "udp_relay_mode": "native",
    "disable_sni": false,
    "reduce_rtt": true
  }
}
EOF

  cat > "$CERT_DIR/clash-tuic.yaml" <<EOF
proxies:
  - name: "TUIC-$_cc"
    type: tuic
    server: $_host
    port: $_port
    uuid: "$_uuid"
    password: "$_pass"
    alpn: ["h3"]
    sni: "$_sni"
    congestion_control: $_cc
    udp_relay_mode: native
    skip-cert-verify: true
    disable_sni: false
    reduce_rtt: true
EOF

  info "节点链接（已保存到 $LINK_FILE）："
  cat "$LINK_FILE"
}

regen_links_from_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  _sni=$(sed -n 's/^TUIC_SNI="\(.*\)"$/\1/p' "$META_FILE" 2>/dev/null | head -n 1)
  _cc=$(sed -n 's/^TUIC_CC="\(.*\)"$/\1/p' "$META_FILE" 2>/dev/null | head -n 1)
  [ -z "$_sni" ] && _sni="www.bing.com"
  [ -z "$_cc" ] && _cc="bbr"
  _port=$(jq -r '.server' "$CONFIG_FILE" 2>/dev/null | sed 's/.*://')
  _uuid=$(jq -r '.users | keys[0]' "$CONFIG_FILE" 2>/dev/null)
  _pass=$(jq -r --arg u "$_uuid" '.users[$u]' "$CONFIG_FILE" 2>/dev/null)
  [ -z "$_port" ] && return 0
  render_all "$_port" "$_uuid" "$_pass" "$_sni" "$_cc"
}

# ---------- 安装 / 升级 ----------
do_install() {
  require_root
  detect_init
  info "======================================="
  info " TUIC v5 安装（OOM 自动重启版）"
  info "======================================="
  install_deps
  detect_init
  stop_service_any
  download_tuic
  gen_certificate
  gen_config
  setup_supervision
  info "启动服务..."
  start_service
  verify_started
  regen_links_from_config
  warn_memory_limit
  info "---------------------------------------"
  info "安装完成"
  info "状态: rc-service tuic status"
  info "日志: $LOG_FILE / $GUARD_LOG"
  info "---------------------------------------"
}

do_upgrade() {
  require_root
  detect_init
  [ -x "$TUIC_BIN" ] || die "未检测到 TUIC（$TUIC_BIN），请先执行安装"
  [ -f "$CONFIG_FILE" ] || die "配置文件不存在: $CONFIG_FILE"
  info "======================================="
  info " 修复 / 升级守护层（保留配置与证书）"
  info "======================================="
  stop_service_any
  setup_supervision
  info "启动服务..."
  start_service
  verify_started
  regen_links_from_config >/dev/null 2>&1
  warn_memory_limit
  info "守护层已更新；如仍异常请查看 $GUARD_LOG"
}

# ---------- 命令 ----------
cmd_status() {
  info "--- 服务状态 ---"
  case "$INIT" in
    openrc)  rc-service tuic status 2>&1 ;;
    systemd) systemctl --no-pager --lines=0 status tuic 2>&1 | head -n 12 ;;
  esac
  _g=$(cat "$GUARD_PIDFILE" 2>/dev/null)
  _t=$(cat "$TUIC_PIDFILE" 2>/dev/null)
  info "守护进程 PID: ${_g:-未运行}"
  info "TUIC 进程 PID: ${_t:-未运行}"
  if [ -n "$_t" ] && [ -r "/proc/$_t/oom_score_adj" ]; then
    info "TUIC oom_score_adj: $(cat "/proc/$_t/oom_score_adj")"
  fi
  _lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  _cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
  [ -n "$_lim" ] && info "内存上限: $_lim 字节（约 $(mb "$_lim") MiB）"
  [ -n "$_cur" ] && info "内存占用: $_cur 字节（约 $(mb "$_cur") MiB）"
  if [ -r /sys/fs/cgroup/memory.events ]; then
    info "OOM 统计: $(awk '/oom_kill/{print "oom_kill="$2}' /sys/fs/cgroup/memory.events)"
  fi
  warn_memory_limit
}

cmd_start() {
  require_root
  start_service
  verify_started
}

cmd_stop() {
  require_root
  stop_service_any
  info "已停止 TUIC"
}

cmd_restart() {
  require_root
  stop_service_any
  start_service
  verify_started
}

cmd_links() {
  [ -f "$LINK_FILE" ] || die "节点信息不存在，请先安装"
  cat "$LINK_FILE"
}

cmd_logs() {
  info "--- $GUARD_LOG（最近 15 行）---"
  tail -n 15 "$GUARD_LOG" 2>/dev/null || warn "无守护日志"
  info "--- $LOG_FILE（最近 10 行）---"
  tail -n 10 "$LOG_FILE" 2>/dev/null || warn "无业务日志"
}

change_port() {
  require_root
  [ -f "$CONFIG_FILE" ] || die "配置文件不存在"
  printf '请输入新的端口号: '
  read NEW_PORT || die "读取输入失败"
  [ -z "$NEW_PORT" ] && die "端口不能为空"
  case "$NEW_PORT" in *[!0-9]*) die "端口必须是数字" ;; esac
  if [ "$NEW_PORT" -lt 1 ] 2>/dev/null || [ "$NEW_PORT" -gt 65535 ] 2>/dev/null; then
    die "端口范围错误"
  fi
  jq --arg s "[::]:$NEW_PORT" '.server=$s' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || die "修改配置失败"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  cmd_restart
  regen_links_from_config
  info "端口已修改为 $NEW_PORT 并已重启服务"
}

cmd_uninstall() {
  require_root
  detect_init
  info "正在卸载 TUIC..."
  stop_service_any
  case "$INIT" in
    openrc)
      rc-update del tuic default >/dev/null 2>&1 || true
      rm -f /etc/init.d/tuic
      sed -i '/tuic-watchdog/d' "$CRON_ROOT" 2>/dev/null || true
      ;;
    systemd)
      systemctl disable tuic >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/tuic.service
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
  esac
  rm -f "$TUIC_BIN" "$GUARD_BIN" "$WATCHDOG_BIN" "$START_SH"
  rm -f "$LOG_FILE" "$GUARD_LOG"
  rm -rf "$CERT_DIR"
  rm -f /root/tuic-links.txt
  sed -i '/tuic-guard.sh/d' /etc/rc.local 2>/dev/null || true
  info "TUIC 已卸载完成（crond 保留，其它定时任务不受影响）"
}

# ---------- 菜单 ----------
menu_installed() {
  info "---------------------------------------"
  info " 检测到已安装 TUIC v5"
  info "---------------------------------------"
  info "1) 查看节点链接"
  info "2) 查看运行状态"
  info "3) 重启服务"
  info "4) 修改端口"
  info "5) 修复/升级守护层（OOM 自动重启）"
  info "6) 查看最近日志"
  info "7) 卸载 TUIC"
  info "8) 退出"
  printf '请输入选项 [1-8]: '
  read choice || die "读取输入失败"
  case "$choice" in
    1) cmd_links ;;
    2) cmd_status ;;
    3) cmd_restart ;;
    4) change_port ;;
    5) do_upgrade ;;
    6) cmd_logs ;;
    7) cmd_uninstall ;;
    8) info "已退出" ;;
    *) warn "无效选项" ;;
  esac
}

menu_fresh() {
  info "---------------------------------------"
  info " 未检测到 TUIC v5"
  info "---------------------------------------"
  info "1) 安装 TUIC v5（含 OOM 自动重启守护）"
  info "2) 退出"
  printf '请输入选项 [1-2]: '
  read choice || die "读取输入失败"
  case "$choice" in
    1) do_install ;;
    2) info "已退出" ;;
    *) warn "无效选项" ;;
  esac
}

usage() {
  cat <<'USAGE_EOF'
TUIC v5 一键脚本（Alpine/OpenRC 优先，兼容 systemd）

用法:
  sh tuic-apline.sh              智能模式：已安装则修复/管理，未安装则直接安装
  sh tuic-apline.sh auto         智能模式（非交互，适合批量部署）
  sh tuic-apline.sh install      安装（有 TTY 时交互，否则用默认值）
  sh tuic-apline.sh upgrade      只修复/升级守护层（保留配置与证书）
  sh tuic-apline.sh status       查看状态 / 内存 / OOM 计数
  sh tuic-apline.sh start        启动
  sh tuic-apline.sh stop         停止
  sh tuic-apline.sh restart      重启
  sh tuic-apline.sh links        查看节点链接
  sh tuic-apline.sh logs         查看最近日志
  sh tuic-apline.sh uninstall    卸载

  “重跑即修复”：已装旧版（旧守护脚本 / 无自启）的机器，直接再运行一次
  sh tuic-apline.sh 或 sh tuic-apline.sh auto，即自动升级守护层并保留配置。

可用环境变量（install 时跳过交互）:
  TUIC_PORT  端口（默认随机）
  TUIC_CC    bbr / cubic（默认 bbr）
  TUIC_SNI   伪装域名（默认 www.bing.com）
  TUIC_CERT  证书 .crt 路径（配合 TUIC_KEY）
  TUIC_KEY   私钥 .key 路径

OOM 说明:
  容器内存上限由宿主固定时无法改大。本脚本让 tuic 的 oom_score_adj=1000，
  内存压力下内核优先杀 tuic；守护进程会在 1~2 秒内自动重启并恢复监听，
  不会误杀 sshd / 守护进程。连续被 OOM 时退避上限 10 秒。
USAGE_EOF
}

# ---------- 入口 ----------
detect_init

case "${1:-}" in
  install)            do_install ;;
  upgrade|fix|repair) do_upgrade ;;
  auto)               require_root; detect_init
                      if [ -x "$TUIC_BIN" ] && [ -f "$CONFIG_FILE" ]; then
                        do_upgrade
                      else
                        info "未检测到 TUIC，开始安装..."
                        do_install
                      fi ;;
  status)             cmd_status ;;
  start)              cmd_start ;;
  stop)               cmd_stop ;;
  restart)            cmd_restart ;;
  links)              cmd_links ;;
  logs)               cmd_logs ;;
  uninstall|remove)   cmd_uninstall ;;
  -h|--help|help)     usage ;;
  '')
    require_root
    detect_init
    if [ -x "$TUIC_BIN" ] && [ -f "$CONFIG_FILE" ]; then
      if supervision_ok; then
        # 已经是新版守护层：交互终端进菜单，非交互只报状态
        if [ -t 0 ]; then
          menu_installed
        else
          cmd_status
        fi
      else
        auto_repair
      fi
    else
      info "未检测到 TUIC，开始安装..."
      do_install
    fi
    ;;
  *) usage; exit 1 ;;
esac
