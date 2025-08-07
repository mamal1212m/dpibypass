#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "You must run this script as root!"
  exit 1
fi

VPN_PORT1=8080
VPN_PORT2=8443
TG_PORT=443

echo "Updating packages and installing prerequisites..."
apt update -y
apt install -y wget unzip openssl python3 python3-pip

echo "Downloading and installing Trojan-Go..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip
unzip -q trojan-go.zip
chmod +x trojan-go
mv trojan-go /usr/local/bin/
cd -
rm -rf "$TMP_DIR"

echo "Creating config folder and generating self-signed certificate..."
mkdir -p /etc/trojan-go
openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1
cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem

echo "Writing Trojan-Go config..."
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
    "reuse_session": true,
    "fallback_addr": "127.0.0.1",
    "fallback_port": $VPN_PORT2
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

echo "Starting Trojan-Go in background..."
nohup trojan-go -config /etc/trojan-go/config.json > /dev/null 2>&1 &

echo "Installing Python package for dummy traffic..."
pip3 install --break-system-packages --quiet --no-cache-dir numpy

echo "Creating dummy traffic script..."
cat > /usr/local/bin/dummy_traffic.py << 'EOF'
import socket
import time
import random

SERVER_IP = "127.0.0.1"
SERVER_PORT = 443

while True:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((SERVER_IP, SERVER_PORT))
        while True:
            size = random.randint(50, 300)
            data = bytes(random.getrandbits(8) for _ in range(size))
            sock.sendall(data)
            time.sleep(random.uniform(0.1, 0.6))
    except Exception:
        time.sleep(1)
    finally:
        try:
            sock.close()
        except:
            pass
EOF

chmod +x /usr/local/bin/dummy_traffic.py

echo "Starting dummy traffic script in background..."
nohup python3 /usr/local/bin/dummy_traffic.py > /dev/null 2>&1 &

echo "All done!"
echo "Trojan-Go TLS port: $TG_PORT"
echo "Internal TCP VPN ports: $VPN_PORT1 and $VPN_PORT2"
