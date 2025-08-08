#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/dpibypass_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "🔐 Starting DPI Bypass setup..."

if [ "$EUID" -ne 0 ]; then
  echo "❌ ERROR: You must run this script as root!"
  exit 1
fi

VPN_PORT1=8080
VPN_PORT2=8443
TG_PORT=443

echo "📦 Updating packages and installing prerequisites..."
apt update -y
apt install -y wget unzip openssl python3 python3-pip || { echo "❌ ERROR: Failed to install prerequisites"; exit 1; }

echo "⬇️ Downloading and installing Trojan-Go..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip
unzip -q trojan-go.zip
chmod +x trojan-go

if [ -f /usr/local/bin/trojan-go ]; then
  echo "🛡️ Backing up existing trojan-go binary..."
  mv /usr/local/bin/trojan-go /usr/local/bin/trojan-go.bak.$(date +%s)
fi

mv trojan-go /usr/local/bin/
cd -
rm -rf "$TMP_DIR"

echo "🔑 Creating config folder and generating self-signed certificate..."
mkdir -p /etc/trojan-go

openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1

cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem
chmod 600 /etc/trojan-go/trojan.key /etc/trojan-go/trojan.pem

echo "✍️ Writing Trojan-Go config with fallback ports $VPN_PORT1 and $VPN_PORT2..."
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
    "fallback_port": $VPN_PORT2,
    "fallback_tls": true,
    "fallback_http_response": "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html><html><body><h1>Hi from fallback!</h1></body></html>"
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

echo "📝 Creating dummy HTTPS traffic script..."

cat > /usr/local/bin/dummy_https_traffic.py << 'EOF'
#!/usr/bin/env python3
import ssl
import socket
import time
import random
import logging
import http.client

logging.basicConfig(filename='/var/log/dummy_traffic.log', level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

SERVER = '127.0.0.1'
PORT = 443
SNI = 'localhost'

def create_https_connection():
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    sock = socket.create_connection((SERVER, PORT), timeout=5)
    ssl_sock = context.wrap_socket(sock, server_hostname=SNI)
    return ssl_sock

def send_dummy_https_requests():
    while True:
        try:
            ssl_sock = create_https_connection()
            logging.info("🔐 TLS handshake successful, connected to server")

            conn = http.client.HTTPSConnection(SERVER, PORT, context=ssl_sock.context)
            conn.sock = ssl_sock

            for _ in range(random.randint(5, 15)):
                path = random.choice(['/','/index.html','/api/data','/favicon.ico'])
                headers = {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36',
                    'Accept-Encoding': 'gzip, deflate',
                    'Accept': '*/*',
                    'Connection': 'keep-alive',
                }
                conn.request("GET", path, headers=headers)
                response = conn.getresponse()
                _ = response.read()
                logging.info(f"➡️ Sent GET {path} - status: {response.status}")

                time.sleep(random.uniform(0.3, 1.2))

            conn.close()
            ssl_sock.close()
            time.sleep(random.uniform(1, 3))

        except Exception as e:
            logging.error(f"❌ Connection error: {e}")
            time.sleep(2)

if __name__ == '__main__':
    send_dummy_https_requests()
EOF

chmod +x /usr/local/bin/dummy_https_traffic.py

echo "🏃‍♂️ Starting dummy HTTPS traffic script in background..."
if pgrep -f dummy_https_traffic.py > /dev/null; then
  echo "🛑 Stopping existing dummy HTTPS traffic process..."
  pkill -f dummy_https_traffic.py
  sleep 2
fi

nohup python3 /usr/local/bin/dummy_https_traffic.py > /var/log/dummy_traffic_out.log 2>&1 &

echo "✅ All done!"
echo "🔐 Trojan-Go TLS port: $TG_PORT"
echo "🔒 Internal TCP VPN ports: $VPN_PORT1 and $VPN_PORT2"
echo "📄 Logs:"
echo "  - $LOGFILE"
echo "  - /var/log/trojan-go.log"
echo "  - /var/log/dummy_traffic.log"
echo "  - /var/log/dummy_traffic_out.log"
