#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/dpibypass_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "\n🔐 Starting Ultimate DPI Bypass Setup...\n"

error_exit() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  error_exit "This script must be run as root!"
fi

# پورت‌ها
TG_PORT=443
VPN_PORT1=8080
VPN_PORT2=8443

echo "📦 Updating package list..."
apt update -y || error_exit "Failed to update package list"

echo "📦 Installing prerequisites..."
apt install -y wget unzip openssl python3 python3-pip systemd iptables nftables || error_exit "Failed to install prerequisites"

echo "⬇️ Downloading Trojan-Go latest release..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR" || error_exit "Failed to enter temp directory"

wget -q https://github.com/p4gefau1t/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip -O trojan-go.zip || error_exit "Failed to download Trojan-Go"
unzip -q trojan-go.zip || error_exit "Failed to unzip Trojan-Go"
chmod +x trojan-go

echo "💾 Installing Trojan-Go binary..."
if [[ -f /usr/local/bin/trojan-go ]]; then
  mv /usr/local/bin/trojan-go /usr/local/bin/trojan-go.bak.$(date +%s) || error_exit "Failed to backup existing trojan-go"
fi
mv trojan-go /usr/local/bin/ || error_exit "Failed to move trojan-go binary"

cd - >/dev/null || error_exit "Failed to return from temp directory"
rm -rf "$TMP_DIR"

echo "🔑 Generating self-signed TLS certificate..."
mkdir -p /etc/trojan-go || error_exit "Failed to create config directory"
openssl req -newkey rsa:4096 -nodes -keyout /etc/trojan-go/trojan.key \
  -x509 -days 3650 -out /etc/trojan-go/trojan.crt -subj "/CN=localhost" >/dev/null 2>&1 || error_exit "Failed to generate TLS certificate"

cat /etc/trojan-go/trojan.crt /etc/trojan-go/trojan.key > /etc/trojan-go/trojan.pem || error_exit "Failed to combine cert and key"
chmod 600 /etc/trojan-go/trojan.key /etc/trojan-go/trojan.pem || error_exit "Failed to set permission on cert/key"

echo "✍️ Writing Trojan-Go configuration..."
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
    "alpn": ["h2","http/1.1"],
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

echo "🐉 Setting up systemd service for Trojan-Go..."
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
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=trojan-go

[Install]
WantedBy=multi-user.target
EOF

echo "🐢 Creating optimized dummy traffic Python script..."
cat > /usr/local/bin/dummy_traffic.py << 'EOF'
import socket
import time
import random
import threading
import logging

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
for _ in range(4):
    t = threading.Thread(target=send_traffic, daemon=True)
    t.start()
    threads.append(t)

while True:
    time.sleep(60)
EOF

chmod +x /usr/local/bin/dummy_traffic.py || error_exit "Failed to set executable on dummy traffic script"

echo "🐢 Creating systemd service for dummy traffic..."
cat > /etc/systemd/system/dummy_traffic.service << EOF
[Unit]
Description=Dummy Traffic Generator Service
After=network.target

[Service]
ExecStart=/usr/bin/nice -n 10 /usr/bin/python3 /usr/local/bin/dummy_traffic.py
Restart=always
CPUQuota=20%
LimitNOFILE=65536
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dummy_traffic

[Install]
WantedBy=multi-user.target
EOF

echo "🛡️ Configuring firewall (iptables + nftables)..."

iptables -F
iptables -X
iptables -Z
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport $TG_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $VPN_PORT1 -j ACCEPT
iptables -A INPUT -p tcp --dport $VPN_PORT2 -j ACCEPT

nft flush ruleset
nft add table inet filter
nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input tcp dport 22 accept
nft add rule inet filter input tcp dport $TG_PORT accept
nft add rule inet filter input tcp dport $VPN_PORT1 accept
nft add rule inet filter input tcp dport $VPN_PORT2 accept

echo "🚀 Reloading systemd daemon and enabling services..."
systemctl daemon-reload || error_exit "Failed to reload systemd"
systemctl enable trojan-go dummy_traffic || error_exit "Failed to enable services"
systemctl restart trojan-go dummy_traffic || error_exit "Failed to start services"

echo -e "\n✅ Setup complete! Services running.\n"
echo "🔐 Trojan-Go TLS port: $TG_PORT"
echo "🔒 Internal VPN TCP ports: $VPN_PORT1, $VPN_PORT2"
echo -e "\n🔎 Check service status with:"
echo "  systemctl status trojan-go"
echo "  systemctl status dummy_traffic"
echo -e "\n📜 Logs:"
echo "  - $LOGFILE"
echo "  - /var/log/syslog (برای لاگ سرویس‌ها)"
echo "  - /var/log/dummy_traffic.log"
