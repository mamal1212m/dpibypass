#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/dpibypass_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "🟢 Starting DPI Bypass setup..."

# Ensure root access
if [ "$EUID" -ne 0 ]; then
  echo "❌ ERROR: This script must be run as root."
  exit 1
fi

# Configuration
VPN_PORT1=8080
TG_PORT=443

# Check for port conflict
if lsof -i :$TG_PORT &>/dev/null; then
  echo "❌ ERROR: Port $TG_PORT is already in use. Stop the conflicting service first."
  exit 1
fi

echo "🔄 Updating system and installing dependencies..."
apt update -y
apt install -y wget unzip openssl python3 python3-pip pipx || {
  echo "❌ ERROR: Failed to install system dependencies."
  exit 1
}
export PATH=$PATH:/root/.local/bin
pipx ensurepath

echo "📦 Downloading and installing Trojan-Go..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip || {
  echo "❌ ERROR: Failed to download Trojan-Go."
  exit 1
}
unzip -q trojan-go.zip || {
  echo "❌ ERROR: Failed to unzip Trojan-Go."
  exit 1
}
chmod +x trojan-go
[ -f /usr/local/bin/trojan-go ] && mv /usr/local/bin/trojan-go "/usr/local/bin/trojan-go.bak.$(date +%s)"
mv trojan-go /usr/local/bin/
cd - && rm -rf "$TMP_DIR"

echo "🔐 Generating self-signed certificate..."
mkdir -p /etc/trojan-go
openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1 || {
  echo "❌ ERROR: Failed to generate SSL certificate."
  exit 1
}
cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem
chmod 600 /etc/trojan-go/trojan.*

echo "⚙️ Writing Trojan-Go config..."
cat > /etc/trojan-go/config.json <<EOF
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

echo "🚦 Starting Trojan-Go..."
pkill -x trojan-go 2>/dev/null || true
nohup trojan-go -config /etc/trojan-go/config.json > /var/log/trojan-go.log 2>&1 &
sleep 3
if ! pgrep -x trojan-go >/dev/null; then
  echo "❌ ERROR: Trojan-Go failed to start. Check /var/log/trojan-go.log"
  exit 1
fi

echo "🧪 Installing numpy in isolated pipx environment..."
pipx install numpy || {
  echo "❌ ERROR: Failed to install numpy via pipx"
  exit 1
}

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

echo "📡 Starting dummy traffic generator..."
pkill -f dummy_traffic.py 2>/dev/null || true
nohup python3 /usr/local/bin/dummy_traffic.py > /var/log/dummy_traffic_out.log 2>&1 &

echo ""
echo "✅ Setup complete!"
echo "Trojan-Go is running on port: $TG_PORT"
echo "Dummy traffic is being sent to localhost:$TG_PORT"
echo "Logs:"
echo "  - Installer:         $LOGFILE"
echo "  - Trojan-Go:         /var/log/trojan-go.log"
echo "  - Dummy traffic:     /var/log/dummy_traffic.log"
echo "  - Traffic output:    /var/log/dummy_traffic_out.log"
