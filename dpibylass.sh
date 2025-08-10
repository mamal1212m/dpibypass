#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/dpibypass_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "🔐 Starting DPI Bypass setup..."

if [ "$EUID" -ne 0 ]; then
  echo -e "❌ ERROR: You must run this script as root!"
  exit 1
fi

VPN_PORT1=8080
VPN_PORT2=8443
TG_PORT=443
WEB_PANEL_PORT=2099

echo -e "📦 Updating packages and installing prerequisites..."
apt update -y
apt install -y wget unzip openssl python3 python3-pip systemd cpulimit || {
  echo -e "❌ ERROR: Failed to install prerequisites"
  exit 1
}

echo -e "⬇️ Downloading and installing Trojan-Go..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip || {
  echo -e "❌ ERROR: Failed to download Trojan-Go"
  exit 1
}
unzip -q trojan-go.zip || {
  echo -e "❌ ERROR: Failed to unzip Trojan-Go"
  exit 1
}

chmod +x trojan-go

if [ -f /usr/local/bin/trojan-go ]; then
  echo -e "💾 Backing up existing trojan-go binary..."
  mv /usr/local/bin/trojan-go /usr/local/bin/trojan-go.bak.$(date +%s)
fi

mv trojan-go /usr/local/bin/
cd -
rm -rf "$TMP_DIR"

echo -e "🔑 Creating config folder and generating self-signed certificate..."
mkdir -p /etc/trojan-go

if ! openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1; then
  echo -e "❌ ERROR: Failed to generate self-signed certificate"
  exit 1
fi

cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem
chmod 600 /etc/trojan-go/trojan.key /etc/trojan-go/trojan.pem

echo -e "✍️ Writing Trojan-Go config..."
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

echo -e "🐉 Setting up Trojan-Go systemd service..."
cat > /etc/systemd/system/trojan-go.service << EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure
Nice=10
CPUQuota=50%
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo -e "📝 Creating optimized dummy traffic Python script..."
cat > /usr/local/bin/dummy_traffic.py << 'EOF'
import socket
import time
import random
import logging
import threading

logging.basicConfig(filename='/var/log/dummy_traffic.log', level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

SERVER_IP = "127.0.0.1"
SERVER_PORT = 443

def send_traffic():
    while True:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((SERVER_IP, SERVER_PORT))
            logging.info("Connected to server")
            while True:
                size = random.randint(100, 500)
                data = bytes(random.getrandbits(8) for _ in range(size))
                sock.sendall(data)
                time.sleep(random.uniform(0.05, 0.3))
        except Exception as e:
            logging.error(f"Connection error: {e}")
            time.sleep(2)
        finally:
            try:
                sock.close()
            except:
                pass

threads = []
for _ in range(3):  # 3 threads for better throughput and randomness
    t = threading.Thread(target=send_traffic, daemon=True)
    t.start()
    threads.append(t)

while True:
    time.sleep(60)
EOF

chmod +x /usr/local/bin/dummy_traffic.py

echo -e "🐢 Creating dummy traffic systemd service..."
cat > /etc/systemd/system/dummy_traffic.service << EOF
[Unit]
Description=Dummy Traffic Generator Service
After=network.target

[Service]
ExecStart=/usr/bin/nice -n 10 /usr/bin/python3 /usr/local/bin/dummy_traffic.py
Restart=always
CPUQuota=20%
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo -e "🛡️ Setting up firewall rules with iptables..."

# Flush all existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established and related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow Trojan-Go TLS port
iptables -A INPUT -p tcp --dport $TG_PORT -j ACCEPT

# Allow VPN internal ports
iptables -A INPUT -p tcp --dport $VPN_PORT1 -j ACCEPT
iptables -A INPUT -p tcp --dport $VPN_PORT2 -j ACCEPT

# Allow web panel port
iptables -A INPUT -p tcp --dport $WEB_PANEL_PORT -j ACCEPT

# Allow HTTP and HTTPS for normal web access if needed
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Allow DNS UDP and TCP
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT

echo -e "🚀 Reloading systemd and enabling services..."
systemctl daemon-reload
systemctl enable trojan-go
systemctl enable dummy_traffic
systemctl restart trojan-go
systemctl restart dummy_traffic

echo -e "✅ Setup complete! Services are running."
echo -e "🔐 Trojan-Go TLS port: $TG_PORT"
echo -e "🔒 Internal TCP VPN ports: $VPN_PORT1 and $VPN_PORT2"
echo -e "🔐 Web Panel port: $WEB_PANEL_PORT"
echo -e "📄 Logs:"
echo -e "  - $LOGFILE"
echo -e "  - /var/log/trojan-go.log"
echo -e "  - /var/log/dummy_traffic.log"

echo -e "\n🔎 To check service status:\n  systemctl status trojan-go\n  systemctl status dummy_traffic"

echo -e "\n🔥 Firewall rules:\n"
iptables -L -n --line-numbers
