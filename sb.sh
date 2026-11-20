#!/usr/bin/env bash
# ============================================================
# sb.sh v1.3 —— sing-box 多协议一键脚本（配合图形面板拼命令使用）
# 用法：HYPT=2082 VLRT=2083 bash <(curl -sL <地址>/sb.sh) install
#
# 协议开关（留空=不启用）：
#   直连：HYPT Hysteria2 | VLRT VLESS-Reality | TUPT TUIC | ANYPT AnyTLS
#   WSCDN  VLESS+WS+TLS 端口（可套 CDN；WSDOMAIN 可填 CDN 域名）
#   SOCKPT Socks5 端口（SOCKUSER / SOCKPWD 可指定账号密码）
#   ARGO   填 1 启用 Argo 隧道（ARGOTOKEN 固定隧道令牌，留空=临时隧道）
#   SUBPT  订阅服务端口（生成 http://地址:端口/sub/令牌 的订阅链接）
#   REPORT 上报地址（安装完成后把节点链接 POST 到这个 webhook）
#   NZ_SERVER / NZ_KEY 哪吒面板地址与探针密钥（都填才装探针；NZ_TLS=1 走 TLS）
#   NZ_VER   哪吒版本：v1 新版面板（默认，配置文件模式）| v0 旧版面板（参数模式）
# 通用：ADDR 服务器地址 | SNI 自签证书名 | RSNI Reality 目标站
#       UUID / HPWD / TPWD / APWD 指定凭据（默认生成并保存）
# 动作：install（默认） rep list start stop restart status del
# 数据目录：$SB_DIR（默认 ~/sb-node）
# ============================================================

SB_DIR="${SB_DIR:-$HOME/sb-node}"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$SB_DIR/cloudflared"
SB_VERSION_PIN="1.14.4"
ACTION="${1:-install}"
ARGO_LOCAL_PORT=18001

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

# ---------- 凭据持久化 ----------
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
  v="${UUID:-$(sec_get UUID)}"; [ -z "$v" ] && v=$(cat /proc/sys/kernel/random/uuid); UUID="$v"; sec_set UUID "$v"
  v="${HPWD:-$(sec_get HPWD)}"; [ -z "$v" ] && v=$(openssl rand -base64 16); HPWD="$v"; sec_set HPWD "$v"
  v="${TPWD:-$(sec_get TPWD)}"; [ -z "$v" ] && v=$(openssl rand -base64 16); TPWD="$v"; sec_set TPWD "$v"
  v="${APWD:-$(sec_get APWD)}"; [ -z "$v" ] && v=$(openssl rand -base64 16); APWD="$v"; sec_set APWD "$v"
  v="${SOCKUSER:-$(sec_get SOCKUSER)}"; [ -z "$v" ] && v="sbuser"; SOCKUSER="$v"; sec_set SOCKUSER "$v"
  v="${SOCKPWD:-$(sec_get SOCKPWD)}"; [ -z "$v" ] && v=$(openssl rand -base64 12); SOCKPWD="$v"; sec_set SOCKPWD "$v"
  v="$(sec_get WSPATH)"; [ -z "$v" ] && v="/$(openssl rand -hex 3)"; WSPATH="$v"; sec_set WSPATH "$v"
  v="$(sec_get ARGOPATH)"; [ -z "$v" ] && v="/$(openssl rand -hex 3)"; ARGOPATH="$v"; sec_set ARGOPATH "$v"
  v="$(sec_get SUBTOKEN)"; [ -z "$v" ] && v=$(openssl rand -hex 8); SUBTOKEN="$v"; sec_set SUBTOKEN "$v"
  v="$(sec_get NZUUID)"; [ -z "$v" ] && v=$(cat /proc/sys/kernel/random/uuid); NZUUID="$v"; sec_set NZUUID "$v"
  SNI="${SNI:-www.bing.com}"
  RSNI="${RSNI:-www.microsoft.com}"
  if [ -n "$VLRT" ]; then
    local priv pub sid out
    priv=$(sec_get RPRIV); pub=$(sec_get RPUB); sid=$(sec_get SID)
    if [ -z "$priv" ]; then
      out=$("$SB_BIN" generate reality-keypair 2>/dev/null)
      priv=$(echo "$out" | grep -i private | awk '{print $2}')
      pub=$(echo "$out" | grep -i public | awk '{print $2}')
      sid=$(openssl rand -hex 4)
      sec_set RPRIV "$priv"; sec_set RPUB "$pub"; sec_set SID "$sid"
    fi
    RPRIV="$priv"; RPUB="$pub"; SID="$sid"
  fi
  ADDR="${ADDR:-$(sec_get ADDR)}"
  [ -z "$ADDR" ] && ADDR=$(public_ip)
  [ -n "$ADDR" ] && sec_set ADDR "$ADDR"
}

load_saved() {
  HYPT=$(sec_get HYPT); VLRT=$(sec_get VLRT); TUPT=$(sec_get TUPT); ANYPT=$(sec_get ANYPT)
  WSCDN=$(sec_get WSCDN); WSDOMAIN=$(sec_get WSDOMAIN); SOCKPT=$(sec_get SOCKPT); SUBPT=$(sec_get SUBPT)
  ARGO=$(sec_get ARGO); ARGODOMAIN=$(sec_get ARGODOM)
  SNI=$(sec_get SNI); RSNI=$(sec_get RSNI); ADDR=$(sec_get ADDR)
  UUID=$(sec_get UUID); HPWD=$(sec_get HPWD); TPWD=$(sec_get TPWD); APWD=$(sec_get APWD)
  SOCKUSER=$(sec_get SOCKUSER); SOCKPWD=$(sec_get SOCKPWD)
  WSPATH=$(sec_get WSPATH); ARGOPATH=$(sec_get ARGOPATH); SUBTOKEN=$(sec_get SUBTOKEN)
  RPUB=$(sec_get RPUB); SID=$(sec_get SID)
  NZ_SERVER=$(sec_get NZ_SERVER); NZ_KEY=$(sec_get NZ_KEY); NZ_TLS=$(sec_get NZ_TLS); NZUUID=$(sec_get NZUUID)
  NZ_VER=$(sec_get NZ_VER)
}

save_form() {
  sec_set HYPT "$HYPT"; sec_set VLRT "$VLRT"; sec_set TUPT "$TUPT"; sec_set ANYPT "$ANYPT"
  sec_set WSCDN "$WSCDN"; sec_set WSDOMAIN "$WSDOMAIN"; sec_set SOCKPT "$SOCKPT"; sec_set SUBPT "$SUBPT"
  sec_set ARGO "$ARGO"; sec_set SNI "$SNI"; sec_set RSNI "$RSNI"
  sec_set NZ_SERVER "$NZ_SERVER"; sec_set NZ_TLS "$NZ_TLS"; sec_set NZ_VER "${NZ_VER:-v1}"
}

# ---------- 本体下载 ----------
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

install_cloudflared() {
  if [ -x "$CF_BIN" ]; then return 0; fi
  local arch
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  info "下载 cloudflared (linux-${arch}) ..."
  curl -sL --max-time 300 -o "$CF_BIN" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
    || { err "cloudflared 下载失败"; return 1; }
  chmod +x "$CF_BIN"
  ok "cloudflared 已就绪"
}

# ---------- 哪吒探针（v1 新版面板 / v0 旧版面板 双支持） ----------
NZ_V0_PIN="v0.20.5"
install_nezha() {
  NZ_VER="${NZ_VER:-v1}"
  local genfile="$SB_DIR/nezha.gen"
  if [ -x "$SB_DIR/nezha-agent" ] && [ -f "$genfile" ] && [ "$(cat "$genfile")" = "$NZ_VER" ]; then return 0; fi
  local arch tmp url tag
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  if [ "$NZ_VER" = "v0" ]; then
    tag=$(curl -s --max-time 10 "https://api.github.com/repos/nezhahq/agent/releases?per_page=100" \
      | grep -o '"tag_name": *"v0\.[^"]*"' | head -1 | sed 's/.*"//;s/"//')
    [ -z "$tag" ] && tag="$NZ_V0_PIN"
    url="https://github.com/nezhahq/agent/releases/download/${tag}/nezha-agent_linux_${arch}.zip"
    info "下载哪吒探针 v0 版 $tag (linux-${arch}) ..."
  else
    url="https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${arch}.zip"
    info "下载哪吒探针 v1 版（官方最新，linux-${arch}）..."
  fi
  tmp=$(mktemp -d)
  curl -sL --max-time 300 -o "$tmp/nz.zip" "$url" \
    || { err "哪吒探针下载失败"; rm -rf "$tmp"; return 1; }
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$tmp/nz.zip" -d "$tmp" || { err "哪吒探针解压失败"; rm -rf "$tmp"; return 1; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/nz.zip" "$tmp" \
      || { err "哪吒探针解压失败"; rm -rf "$tmp"; return 1; }
  else
    err "没有 unzip 也没有 python3，解压不了哪吒探针"; rm -rf "$tmp"; return 1
  fi
  cp "$tmp/nezha-agent" "$SB_DIR/nezha-agent"
  chmod +x "$SB_DIR/nezha-agent"; rm -rf "$tmp"
  echo "$NZ_VER" > "$genfile"
  ok "哪吒探针已就绪（$NZ_VER 版）"
}

start_nezha() {
  [ -n "$NZ_SERVER" ] && [ -n "$NZ_KEY" ] || return 0
  NZ_VER="${NZ_VER:-v1}"
  install_nezha || return 1
  local cmd
  if [ "$NZ_VER" = "v0" ]; then
    # v0 旧版：参数模式，没有配置文件；v0 探针不支持 TLS 开关
    [ "$NZ_TLS" = "1" ] && warn "v0 探针不支持 TLS 参数，已忽略 NZ_TLS"
    cmd="$SB_DIR/nezha-agent -s $NZ_SERVER -p $NZ_KEY"
  else
    local tls="false"
    [ "$NZ_TLS" = "1" ] && tls="true"
    cat > "$SB_DIR/nezha.yml" <<EOF
debug: false
server: $NZ_SERVER
client_secret: $NZ_KEY
tls: $tls
uuid: $NZUUID
report_delay: 3
EOF
    chmod 600 "$SB_DIR/nezha.yml" 2>/dev/null
    cmd="$SB_DIR/nezha-agent -c $SB_DIR/nezha.yml"
  fi
  if has_systemd; then
    _unit sb-nezha "nezha agent (sb.sh)" "$cmd"
    sleep 1
    systemctl is-active --quiet sb-nezha && ok "哪吒探针已启动（$NZ_VER 版，面板 $NZ_SERVER）" || warn "哪吒探针启动异常，查 journalctl -u sb-nezha"
  else
    _kill_pid nezha
    _run_bg nezha "$cmd"
    sleep 1
    _pid_alive nezha && ok "哪吒探针已启动（$NZ_VER 版，面板 $NZ_SERVER）" || warn "哪吒探针启动异常，看 $SB_DIR/nezha.log"
  fi
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
  add_in() { inbounds+="$sep$1"; sep=","; }
  if [ -n "$HYPT" ]; then add_in "$(cat <<EOF
{
      "type": "hysteria2", "tag": "hy2-in",
      "listen": "::", "listen_port": $HYPT,
      "users": [ { "password": "$HPWD" } ],
      "tls": { "enabled": true, "server_name": "$SNI",
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)"; fi
  if [ -n "$VLRT" ]; then add_in "$(cat <<EOF
{
      "type": "vless", "tag": "reality-in",
      "listen": "::", "listen_port": $VLRT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "$RSNI",
               "reality": { "enabled": true,
                            "handshake": { "server": "$RSNI", "server_port": 443 },
                            "private_key": "$RPRIV", "short_id": [ "$SID" ] } }
    }
EOF
)"; fi
  if [ -n "$TUPT" ]; then add_in "$(cat <<EOF
{
      "type": "tuic", "tag": "tuic-in",
      "listen": "::", "listen_port": $TUPT,
      "users": [ { "uuid": "$UUID", "password": "$TPWD" } ],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$SNI", "alpn": [ "h3" ],
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)"; fi
  if [ -n "$ANYPT" ]; then add_in "$(cat <<EOF
{
      "type": "anytls", "tag": "anytls-in",
      "listen": "::", "listen_port": $ANYPT,
      "users": [ { "password": "$APWD" } ],
      "tls": { "enabled": true, "server_name": "$SNI",
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)"; fi
  if [ -n "$WSCDN" ]; then add_in "$(cat <<EOF
{
      "type": "vless", "tag": "ws-in",
      "listen": "::", "listen_port": $WSCDN,
      "users": [ { "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "$WSPATH" },
      "tls": { "enabled": true, "server_name": "${WSDOMAIN:-$SNI}",
               "certificate_path": "$SB_DIR/cert.pem", "key_path": "$SB_DIR/key.pem" }
    }
EOF
)"; fi
  if [ -n "$ARGO" ]; then add_in "$(cat <<EOF
{
      "type": "vless", "tag": "argo-in",
      "listen": "127.0.0.1", "listen_port": $ARGO_LOCAL_PORT,
      "users": [ { "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "$ARGOPATH" }
    }
EOF
)"; fi
  if [ -n "$SOCKPT" ]; then add_in "$(cat <<EOF
{
      "type": "socks", "tag": "socks-in",
      "listen": "::", "listen_port": $SOCKPT,
      "users": [ { "username": "$SOCKUSER", "password": "$SOCKPWD" } ]
    }
EOF
)"; fi
  if [ -z "$inbounds" ]; then
    err "一个协议都没启用：至少填 HYPT / VLRT / TUPT / ANYPT / WSCDN / SOCKPT 中的一个，或 ARGO=1"
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
  if [ -n "$WSCDN" ]; then
    local wa="${WSDOMAIN:-$ADDR}"
    out+="vless://${UUID}@${wa}:${WSCDN}?encryption=none&security=tls&sni=${wa}&type=ws&path=$(urlencode "$WSPATH")&allowInsecure=1#ws-${wa}"$'\n'
  fi
  if [ -n "$ARGO" ] && [ -n "$ARGODOMAIN" ]; then
    out+="vless://${UUID}@${ARGODOMAIN}:443?encryption=none&security=tls&sni=${ARGODOMAIN}&type=ws&host=${ARGODOMAIN}&path=$(urlencode "$ARGOPATH")#argo-${ARGODOMAIN}"$'\n'
  fi
  [ -n "$SOCKPT" ] && out+="socks5://${SOCKUSER}:$(urlencode "$SOCKPWD")@${ADDR}:${SOCKPT}#socks-${ADDR}"$'\n'
  echo -n "$out" > "$SB_DIR/links.txt"
  echo "$out"
}

sub_url() { [ -n "$SUBPT" ] && echo "http://${ADDR}:${SUBPT}/sub/${SUBTOKEN}"; }

make_sub() {
  base64 -w 0 "$SB_DIR/links.txt" > "$SB_DIR/sub.txt" 2>/dev/null || base64 "$SB_DIR/links.txt" | tr -d '\n' > "$SB_DIR/sub.txt"
}

# ---------- 订阅小服务器（只认 /sub/<令牌> 一个路径） ----------
write_sub_server() {
  cat > "$SB_DIR/sub_server.py" <<'PYEOF'
import http.server, os, sys
BASE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]); TOKEN = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/sub/" + TOKEN:
            try:
                data = open(os.path.join(BASE, "sub.txt"), "rb").read()
            except OSError:
                data = b""
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
}

# ---------- 进程托管（sing-box / cloudflared / 订阅，三件套） ----------
_unit() { # _unit 单元名 描述 命令...
  local name="$1" desc="$2"; shift 2
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$desc
After=network.target

[Service]
Type=simple
ExecStart=$*
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$name" >/dev/null 2>&1
  systemctl restart "$name"
}

_run_bg() { # _run_bg 名字 命令行（nohup 模式，写 pid 与 log）
  local name="$1" cmd="$2"
  cat > "$SB_DIR/run-$name.sh" <<EOF
#!/bin/sh
cd $SB_DIR || exit 1
nohup $cmd >> $name.log 2>&1 &
echo \$! > $SB_DIR/$name.pid
EOF
  chmod +x "$SB_DIR/run-$name.sh"
  sh "$SB_DIR/run-$name.sh"
}

_kill_pid() { # _kill_pid 名字
  local name="$1"
  if [ -f "$SB_DIR/$name.pid" ]; then
    kill "$(cat "$SB_DIR/$name.pid")" 2>/dev/null
    rm -f "$SB_DIR/$name.pid"
  fi
}

_pid_alive() { [ -f "$SB_DIR/$1.pid" ] && kill -0 "$(cat "$SB_DIR/$1.pid")" 2>/dev/null; }

start_singbox() {
  if has_systemd; then
    _unit sb-panel "sing-box multi-protocol node (sb.sh)" "$SB_BIN run -c $SB_DIR/config.json"
    sleep 1
    systemctl is-active --quiet sb-panel && ok "sing-box 已启动（systemd）" || { err "sing-box 启动失败，看 $SB_DIR/sing-box.log 或 journalctl -u sb-panel"; return 1; }
  else
    if _pid_alive main; then warn "sing-box 已在运行"; return 0; fi
    _run_bg main "$SB_BIN run -c config.json"
    sleep 1
    _pid_alive main && ok "sing-box 已启动（nohup，PID $(cat "$SB_DIR/main.pid")）" || { err "sing-box 启动失败，看 $SB_DIR/main.log"; return 1; }
  fi
}

start_argo() {
  [ -n "$ARGO" ] || return 0
  install_cloudflared || return 1
  local cmd
  if [ -n "$ARGOTOKEN" ]; then
    cmd="$CF_BIN tunnel run --token $ARGOTOKEN"
    [ -n "$ARGODOMAIN" ] && sec_set ARGODOM "$ARGODOMAIN"
  else
    cmd="$CF_BIN tunnel --url http://127.0.0.1:$ARGO_LOCAL_PORT --no-autoupdate"
  fi
  if has_systemd; then
    _unit sb-argo "cloudflared argo tunnel (sb.sh)" "$cmd"
  else
    _kill_pid argo
    _run_bg argo "$cmd"
  fi
  if [ -z "$ARGOTOKEN" ]; then
    # 临时隧道：等日志里出现 trycloudflare 域名
    local i dom=""
    for i in $(seq 1 20); do
      sleep 1
      if has_systemd; then
        dom=$(journalctl -u sb-argo --no-pager -n 80 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | grep -v 'api\.trycloudflare' | head -1)
      else
        dom=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$SB_DIR/argo.log" 2>/dev/null | grep -v 'api\.trycloudflare' | head -1)
      fi
      [ -n "$dom" ] && break
    done
    if [ -n "$dom" ]; then
      ARGODOMAIN="${dom#https://}"
      sec_set ARGODOM "$ARGODOMAIN"
      ok "Argo 临时隧道已通：$dom"
    else
      warn "Argo 隧道域名暂未拿到（cloudflared 可能还在连），稍后跑 list 再看，或查 argo 日志"
    fi
  else
    ok "Argo 固定隧道已启动（令牌模式）"
  fi
}

start_sub() {
  [ -n "$SUBPT" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "没有 python3，订阅服务没法起；订阅内容已生成在 $SB_DIR/sub.txt，可手动取用"
    return 0
  fi
  write_sub_server
  if has_systemd; then
    _unit sb-sub "subscription server (sb.sh)" "/usr/bin/env python3 $SB_DIR/sub_server.py $SUBPT $SUBTOKEN"
  else
    _kill_pid sub
    _run_bg sub "python3 sub_server.py $SUBPT $SUBTOKEN"
  fi
  sleep 1
  ok "订阅服务已启动：$(sub_url)"
}

stop_all() {
  if has_systemd; then
    systemctl stop sb-panel sb-argo sb-sub sb-nezha 2>/dev/null
    systemctl disable sb-panel sb-argo sb-sub sb-nezha >/dev/null 2>&1
  fi
  _kill_pid main; _kill_pid argo; _kill_pid sub; _kill_pid nezha
  local p
  p=$(pgrep -f "sing-box run -c $SB_DIR/config.json" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null
  p=$(pgrep -f "$SB_DIR/cloudflared tunnel" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null
  p=$(pgrep -f "sub_server.py $SUBPT" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null
  p=$(pgrep -f "$SB_DIR/nezha-agent" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null
  ok "全部服务已停止"
}

main_running() {
  if has_systemd && systemctl is-active --quiet sb-panel 2>/dev/null; then return 0; fi
  if _pid_alive main; then return 0; fi
  pgrep -f "sing-box run -c $SB_DIR/config.json" >/dev/null 2>&1
}

# ---------- 上报 ----------
do_report() {
  [ -n "$REPORT" ] || return 0
  sec_set REPORT "$REPORT"
  if command -v python3 >/dev/null 2>&1; then
    REPORT="$REPORT" SB_DIR="$SB_DIR" ADDR="$ADDR" python3 - <<'PYEOF' >/dev/null 2>&1
import json, os, urllib.request
links = open(os.path.join(os.environ["SB_DIR"], "links.txt")).read().strip().splitlines()
body = json.dumps({"server": os.environ.get("ADDR", ""), "action": "install",
                   "links": links,
                   "text": "节点已安装\n" + "\n".join(links)}).encode()
req = urllib.request.Request(os.environ["REPORT"], data=body,
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10)
PYEOF
    ok "已上报到 $REPORT"
  else
    warn "没有 python3，跳过上报"
  fi
}

# ---------- 动作 ----------
do_install() {
  mkdir -p "$SB_DIR"
  install_binary || exit 1
  prepare_secrets
  [ -z "$ADDR" ] && { err "拿不到服务器地址，请用 ADDR=地址 指定"; exit 1; }
  gen_cert || { err "证书生成失败"; exit 1; }
  save_form
  [ -n "$REPORT" ] && sec_set REPORT "$REPORT"
  [ -n "$NZ_KEY" ] && sec_set NZ_KEY "$NZ_KEY"
  if ! build_config; then err "配置校验未通过"; exit 1; fi
  stop_all >/dev/null 2>&1
  start_singbox || exit 1
  start_argo
  start_nezha
  echo
  ok "分享链接（已存 $SB_DIR/links.txt）："
  build_links
  if [ -n "$SUBPT" ]; then
    make_sub
    start_sub
    echo "订阅链接：$(sub_url)"
  fi
  if command -v qrencode >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -n "$line" ] && { echo; qrencode -t ANSIUTF8 "$line"; }
    done < "$SB_DIR/links.txt"
  fi
  do_report
}

do_list() {
  [ -f "$SECRETS" ] || { err "还没安装过，先跑 install"; exit 1; }
  load_saved
  REPORT=$(sec_get REPORT)
  echo "sing-box：$(main_running && echo 运行中 || echo 已停止)"
  [ -n "$NZ_SERVER" ] && echo "哪吒探针：面板 $NZ_SERVER"
  [ -n "$ARGO" ] && echo "Argo 隧道域名：${ARGODOMAIN:-未获取}"
  echo "分享链接："
  build_links
  [ -n "$SUBPT" ] && echo "订阅链接：$(sub_url)"
}

case "$ACTION" in
  install|rep) do_install ;;
  list) do_list ;;
  start)
    load_saved
    start_singbox; start_argo; start_nezha
    [ -n "$SUBPT" ] && { make_sub; start_sub; }
    ;;
  stop) stop_all ;;
  restart) load_saved; stop_all; start_singbox; start_argo; start_nezha; [ -n "$SUBPT" ] && start_sub ;;
  status)
    echo "sing-box：$(main_running && echo 运行中 || echo 已停止)"
    tail -5 "$SB_DIR/main.log" 2>/dev/null || journalctl -u sb-panel --no-pager -n 5 2>/dev/null
    ;;
  del)
    stop_all
    if has_systemd; then
      rm -f /etc/systemd/system/sb-panel.service /etc/systemd/system/sb-argo.service /etc/systemd/system/sb-sub.service /etc/systemd/system/sb-nezha.service
      systemctl daemon-reload 2>/dev/null
    fi
    rm -rf "$SB_DIR"
    ok "已卸载并删除 $SB_DIR"
    ;;
  *) err "未知动作：$ACTION（可用 install rep list start stop restart status del）"; exit 1 ;;
esac
