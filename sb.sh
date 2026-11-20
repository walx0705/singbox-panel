#!/usr/bin/env bash
# ============================================================
# sb.sh —— sing-box 多协议一键脚本（配合图形面板生成命令使用）
# 用法：HYPT=2082 VLRT=2083 bash <(curl -sL <地址>/sb.sh) install
#
# 环境变量（留空=不启用该协议）：
#   HYPT   Hysteria2 端口        VLRT  VLESS-Reality 端口
#   TUPT   TUIC 端口             ANYPT AnyTLS 端口
#   ADDR   服务器地址（链接用，默认自动取公网 IP）
#   SNI    自签证书名（HY2/TUIC/AnyTLS 用，默认 www.bing.com）
#   RSNI   Reality 目标站（默认 www.microsoft.com）
#   UUID   指定 UUID（默认生成并保存）
#   HPWD   HY2 密码（默认生成并保存）
#   TPWD   TUIC 密码（默认生成并保存）
#   APWD   AnyTLS 密码（默认生成并保存）
# 动作（第一个参数）：install（默认） rep list start stop restart status del
# 数据目录：$SB_DIR（默认 ~/sb-node），含配置、证书、密钥、链接、日志。
# ============================================================

SB_DIR="${SB_DIR:-$HOME/sb-node}"
SB_BIN="$SB_DIR/sing-box"
SB_VERSION_PIN="1.14.4"
ACTION="${1:-install}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[信息]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[注意]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*"; }

has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

urlencode() { echo -n "$1" | sed -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'; }

public_ip() {
  local ip
  ip=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)
  [ -z "$ip" ] && ip=$(curl -s --max-time 6 https://ip.sb 2>/dev/null)
  echo "$ip" | tr -d ' \n'
}

# ---------- 密钥/密码（生成后存 secrets，rep 时复用） ----------
SECRETS="$SB_DIR/secrets"
sec_get() { [ -f "$SECRETS" ] && grep "^$1=" "$SECRETS" | head -1 | cut -d= -f2-; }
sec_set() {
  touch "$SECRETS"
  grep -v "^$1=" "$SECRETS" > "$SECRETS.tmp" 2>/dev/null; mv "$SECRETS.tmp" "$SECRETS"
  echo "$1=$2" >> "$SECRETS"
  chmod 600 "$SECRETS" 2>/dev/null
}

prepare_secrets() {
  mkdir -p "$SB_DIR"
  local v
  v="${UUID:-$(sec_get UUID)}";  [ -z "$v" ] && v=$(cat /proc/sys/kernel/random/uuid); UUID="$v";  sec_set UUID "$v"
  v="${HPWD:-$(sec_get HPWD)}";  [ -z "$v" ] && v=$(openssl rand -base64 16);        HPWD="$v";  sec_set HPWD "$v"
  v="${TPWD:-$(sec_get TPWD)}";  [ -z "$v" ] && v=$(openssl rand -base64 16);        TPWD="$v";  sec_set TPWD "$v"
  v="${APWD:-$(sec_get APWD)}";  [ -z "$v" ] && v=$(openssl rand -base64 16);        APWD="$v";  sec_set APWD "$v"
  SNI="${SNI:-www.bing.com}"
  RSNI="${RSNI:-www.microsoft.com}"
  if [ -n "$VLRT" ]; then
    local priv pub sid
    priv=$(sec_get RPRIV); pub=$(sec_get RPUB); sid=$(sec_get SID)
    if [ -z "$priv" ]; then
      local out
      out=$("$SB_BIN" generate reality-keypair 2>/dev/null)
      priv=$(echo "$out" | grep -i private | awk '{print $2}')
      pub=$(echo "$out" | grep -i public | awk '{print $2}')
      sid=$(openssl rand -hex 4)
      sec_set RPRIV "$priv"; sec_set RPUB "$pub"; sec_set SID "$sid"
    fi
    RPRIV="$priv"; RPUB="$pub"; SID="$sid"
  fi
  ADDR="${ADDR:-$(sec_get ADDR)}"
  if [ -z "$ADDR" ]; then ADDR=$(public_ip); fi
  [ -n "$ADDR" ] && sec_set ADDR "$ADDR"
}

# ---------- sing-box 本体 ----------
install_binary() {
  if [ -x "$SB_BIN" ]; then return 0; fi
  local arch ver url tmp
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  ver=$(curl -s --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//;s/"//')
  [ -z "$ver" ] && ver="$SB_VERSION_PIN"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  info "下载 sing-box v${ver} (linux-${arch}) ..."
  tmp=$(mktemp -d)
  curl -sL --max-time 300 -o "$tmp/sb.tar.gz" "$url" || { err "下载失败"; rm -rf "$tmp"; return 1; }
  tar xzf "$tmp/sb.tar.gz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  cp "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$SB_BIN"
  chmod +x "$SB_BIN"; rm -rf "$tmp"
  ok "sing-box 已就绪：$("$SB_BIN" version | head -1)"
}

gen_cert() {
  if [ -f "$SB_DIR/cert.pem" ] && [ -f "$SB_DIR/key.pem" ]; then return 0; fi
  if openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/key.pem" 2>/dev/null; then
    openssl req -new -x509 -days 3650 -key "$SB_DIR/key.pem" -out "$SB_DIR/cert.pem" -subj "/CN=$SNI" 2>/dev/null
  else
    openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
      -keyout "$SB_DIR/key.pem" -out "$SB_DIR/cert.pem" -subj "/CN=$SNI" 2>/dev/null
  fi
  [ -f "$SB_DIR/cert.pem" ]
}

# ---------- 配置组装 ----------
build_config() {
  local inbounds="" sep=""
  if [ -n "$HYPT" ]; then
    inbounds+=$(cat <<EOF
$sep{
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HYPT,
      "users": [ { "password": "$HPWD" } ],
      "tls": { "enabled": true, "server_name": "$SNI",
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)
    sep=","
  fi
  if [ -n "$VLRT" ]; then
    inbounds+=$(cat <<EOF
$sep{
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $VLRT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "$RSNI",
               "reality": { "enabled": true,
                            "handshake": { "server": "$RSNI", "server_port": 443 },
                            "private_key": "$RPRIV", "short_id": [ "$SID" ] } }
    }
EOF
)
    sep=","
  fi
  if [ -n "$TUPT" ]; then
    inbounds+=$(cat <<EOF
$sep{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $TUPT,
      "users": [ { "uuid": "$UUID", "password": "$TPWD" } ],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$SNI", "alpn": [ "h3" ],
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)
    sep=","
  fi
  if [ -n "$ANYPT" ]; then
    inbounds+=$(cat <<EOF
$sep{
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $ANYPT,
      "users": [ { "password": "$APWD" } ],
      "tls": { "enabled": true, "server_name": "$SNI",
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)
    sep=","
  fi
  if [ -z "$inbounds" ]; then
    err "一个协议都没启用：至少给 HYPT / VLRT / TUPT / ANYPT 中的一个填端口"
    return 1
  fi
  cat > "$SB_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [ $inbounds
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  "$SB_BIN" check -c "$SB_DIR/config.json"
}

# ---------- 链接 ----------
build_links() {
  local out=""
  [ -n "$HYPT" ] && out+="hysteria2://$(urlencode "$HPWD")@${ADDR}:${HYPT}?sni=${SNI}&insecure=1#hy2-${ADDR}"$'\n'
  [ -n "$VLRT" ] && out+="vless://${UUID}@${ADDR}:${VLRT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RSNI}&fp=chrome&pbk=${RPUB}&sid=${SID}&type=tcp#reality-${ADDR}"$'\n'
  [ -n "$TUPT" ] && out+="tuic://${UUID}:$(urlencode "$TPWD")@${ADDR}:${TUPT}?sni=${SNI}&insecure=1&alpn=h3#tuic-${ADDR}"$'\n'
  [ -n "$ANYPT" ] && out+="anytls://$(urlencode "$APWD")@${ADDR}:${ANYPT}?sni=${SNI}&insecure=1#anytls-${ADDR}"$'\n'
  echo -n "$out" > "$SB_DIR/links.txt"
  echo "$out"
}

# ---------- 服务托管 ----------
svc_start() {
  if has_systemd; then
    cat > /etc/systemd/system/sb-panel.service <<EOF
[Unit]
Description=sing-box multi-protocol node (sb.sh)
After=network.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $SB_DIR/config.json
Restart=on-failure
StandardOutput=append:$SB_DIR/sing-box.log
StandardError=append:$SB_DIR/sing-box.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sb-panel >/dev/null 2>&1
    systemctl restart sb-panel
    sleep 1
    systemctl is-active --quiet sb-panel && ok "服务已启动（systemd）" || { err "服务启动失败，看 $SB_DIR/sing-box.log"; return 1; }
  else
    if [ -f "$SB_DIR/pid" ] && kill -0 "$(cat "$SB_DIR/pid")" 2>/dev/null; then
      warn "服务已在运行（PID $(cat "$SB_DIR/pid")）"; return 0
    fi
    cat > "$SB_DIR/start.sh" <<EOF
#!/bin/sh
cd $SB_DIR || exit 1
nohup $SB_BIN run -c config.json >> sing-box.log 2>&1 &
echo \$! > $SB_DIR/pid
EOF
    chmod +x "$SB_DIR/start.sh"
    sh "$SB_DIR/start.sh"
    sleep 1
    if [ -f "$SB_DIR/pid" ] && kill -0 "$(cat "$SB_DIR/pid")" 2>/dev/null; then
      ok "服务已启动（nohup，PID $(cat "$SB_DIR/pid")）"
    else
      err "服务启动失败，看 $SB_DIR/sing-box.log"; return 1
    fi
  fi
}

svc_stop() {
  if has_systemd; then
    systemctl stop sb-panel 2>/dev/null
    systemctl disable sb-panel >/dev/null 2>&1
  fi
  if [ -f "$SB_DIR/pid" ]; then
    kill "$(cat "$SB_DIR/pid")" 2>/dev/null; rm -f "$SB_DIR/pid"
  fi
  local p
  p=$(pgrep -f "sing-box run -c $SB_DIR/config.json" 2>/dev/null)
  [ -n "$p" ] && kill $p 2>/dev/null
  ok "服务已停止"
}

svc_running() {
  if has_systemd && systemctl is-active --quiet sb-panel 2>/dev/null; then return 0; fi
  if [ -f "$SB_DIR/pid" ] && kill -0 "$(cat "$SB_DIR/pid")" 2>/dev/null; then return 0; fi
  pgrep -f "sing-box run -c $SB_DIR/config.json" >/dev/null 2>&1
}

# ---------- 动作 ----------
do_install() {
  mkdir -p "$SB_DIR"
  install_binary || exit 1
  prepare_secrets
  [ -z "$ADDR" ] && { err "拿不到服务器地址，请用 ADDR=地址 指定"; exit 1; }
  gen_cert || { err "证书生成失败"; exit 1; }
  # 记住本次端口组合，list 时复用
  sec_set HYPT "$HYPT"; sec_set VLRT "$VLRT"; sec_set TUPT "$TUPT"; sec_set ANYPT "$ANYPT"
  sec_set SNI "$SNI"; sec_set RSNI "$RSNI"
  if ! build_config; then err "配置校验未通过"; exit 1; fi
  svc_stop >/dev/null 2>&1
  svc_start || exit 1
  echo
  ok "安装完成，分享链接（已存 $SB_DIR/links.txt）："
  build_links
  if command -v qrencode >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -n "$line" ] && { echo; qrencode -t ANSIUTF8 "$line"; }
    done < "$SB_DIR/links.txt"
  fi
}

do_list() {
  [ -f "$SB_DIR/secrets" ] || { err "还没安装过，先跑 install"; exit 1; }
  HYPT=$(sec_get HYPT); VLRT=$(sec_get VLRT); TUPT=$(sec_get TUPT); ANYPT=$(sec_get ANYPT)
  SNI=$(sec_get SNI); RSNI=$(sec_get RSNI); ADDR=$(sec_get ADDR)
  UUID=$(sec_get UUID); HPWD=$(sec_get HPWD); TPWD=$(sec_get TPWD); APWD=$(sec_get APWD)
  RPUB=$(sec_get RPUB); SID=$(sec_get SID)
  echo "服务状态：$(svc_running && echo 运行中 || echo 已停止)"
  echo "分享链接："
  build_links
}

case "$ACTION" in
  install|rep) do_install ;;
  list) do_list ;;
  start) svc_start ;;
  stop) svc_stop ;;
  restart) svc_stop; svc_start ;;
  status) echo "服务状态：$(svc_running && echo 运行中 || echo 已停止)"; tail -5 "$SB_DIR/sing-box.log" 2>/dev/null ;;
  del)
    svc_stop
    if has_systemd; then rm -f /etc/systemd/system/sb-panel.service; systemctl daemon-reload 2>/dev/null; fi
    rm -rf "$SB_DIR"
    ok "已卸载并删除 $SB_DIR"
    ;;
  *) err "未知动作：$ACTION（可用 install rep list start stop restart status del）"; exit 1 ;;
esac
