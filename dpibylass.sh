#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/dpibypass_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

print_lock() {
  frames=(
    "🔒        "
    " 🔒       "
    "  🔒      "
    "   🔒     "
    "    🔒    "
    "     🔒   "
    "      🔒  "
    "       🔒 "
    "        🔒"
    "       🔒 "
    "      🔒  "
    "     🔒   "
    "    🔒    "
    "   🔒     "
    "  🔒      "
    " 🔒       "
  )
  for i in {1..3}; do
    for frame in "${frames[@]}"; do
      echo -ne "\r$frame DPI Bypass is locking... 🔐"
      sleep 0.1
    done
  done
  echo -e "\r🔒 DPI Bypass setup starting...           "
}

print_lock

if [ "$EUID" -ne 0 ]; then
  echo "❌ ERROR: You must run this script as root!"
  exit 1
fi

VPN_PORT1=8080
VPN_PORT2=8443
TG_PORT=443

echo "⬇️ Updating packages and installing prerequisites..."
apt update -y
apt install -y wget unzip openssl python3 python3-pip || { echo "❌ ERROR: Failed to install prerequisites"; exit 1; }

echo "⬇️ Downloading and installing Trojan-Go..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
if ! wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip; then
  echo "❌ ERROR: Failed to download Trojan-Go"
  exit 1
fi

if ! unzip -q trojan-go.zip; then
  echo "❌ ERROR: Failed to unzip Trojan-Go"
  exit 1
fi

chmod +x trojan-go

if [ -f /usr/local/bin/trojan-go ]; then
  echo "📦 Backing up existing trojan-go binary..."
  mv /usr/local/bin/trojan-go /usr/local/bin/trojan-go.bak.$(date +%s)
fi

mv trojan-go /usr/local/bin/
cd -
rm -rf "$TMP_DIR"

echo "🔑 Creating config folder and generating self-signed certificate..."
mkdir -p /etc/trojan-go

if ! openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1; then
  echo "❌ ERROR: Failed to generate self-signed certificate"
  exit 1
fi

cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem
chmod 600 /etc/trojan-go/trojan.key /etc/trojan-go/trojan.pem

echo "✍️ Writing Trojan-Go config without fallback..."
cat > /etc/trojan-go/config.json << EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": $TG_PORT,
  "remote_addr": "127.0.0.1",
  "remote_port": $VPN_PORT1,
  "password": [],
  "ssl": {
    "cert": "/etc/trojan-go/trojan.pem",
    "key": "/etc/trojan-go/trojan.key",
    "sni": "localhost",
    "alpn": ["h2", "http/1.1"],
    "session_ticket": true,
    "reuse_session": true
  },
  "mux": {
    "enabled": true,
    "concurrency": 16
  },
  "packet_padding": {
    "enabled": true,
    "max_padding_len": 256
  }
}
EOF

echo "🚀 Starting Trojan-Go in background..."
if pgrep -x "trojan-go" > /dev/null; then
  echo "🛑 Stopping existing trojan-go process..."
  pkill trojan-go
  sleep 2
fi

nohup trojan-go -config /etc/trojan-go/config.json > /var/log/trojan-go.log 2>&1 &
sleep 3

if ! pgrep -x "trojan-go" > /dev/null; then
  echo "❌ ERROR: Trojan-Go failed to start. Check /var/log/trojan-go.log"
  exit 1
fi

echo "🐍 Installing Python package for dummy traffic..."

if ! command -v pipx &>/dev/null; then
  echo "⬇️ pipx not found, installing pipx..."
  apt install -y pipx
  export PATH=$PATH:/home/$SUDO_USER/.local/bin
fi

echo "⬇️ Installing numpy with pipx..."
pipx install numpy || { echo "❌ ERROR: Failed to install numpy with pipx"; exit 1; }

echo "📝 Creating dummy traffic script..."
cat > /usr/local/bin/dummy_traffic.py << 'EOF'
import socket
import time
import random
import logging

logging.basicConfig(filename='/var/log/dummy_traffic.log', level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

SERVER_IP = "127.0.0.1"
SERVER_PORT = 443

while True:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((SERVER_IP, SERVER_PORT))
        logging.info("Connected to server")
        while True:
            size = random.randint(50, 300)
            data = bytes(random.getrandbits(8) for _ in range(size))
            sock.sendall(data)
            time.sleep(random.uniform(0.1, 0.6))
    except Exception as e:
        logging.error(f"Connection error: {e}")
        time.sleep(1)
    finally:
        try:
            sock.close()
        except:
            pass
EOF

chmod +x /usr/local/bin/dummy_traffic.py

echo "🏃‍♂️ Starting dummy traffic script in background..."
if pgrep -f dummy_traffic.py > /dev/null; then
  echo "🛑 Stopping existing dummy_traffic.py process..."
  pkill -f dummy_traffic.py
  sleep 2
fi

nohup python3 /usr/local/bin/dummy_traffic.py > /var/log/dummy_traffic_out.log 2>&1 &

echo "✅ All done!"
echo "🔐 Trojan-Go TLS port: $TG_PORT"
echo "🔒 Internal TCP VPN ports: $VPN_PORT1 and $VPN_PORT2"
echo "📄 Logs:"
echo "  - $LOGFILE"
echo "  - /var/log/trojan-go.log"
echo "  - /var/log/dummy_traffic.log"
echo "  - /var/log/dummy_traffic_out.log"
