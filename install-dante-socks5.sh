#!/bin/bash

set -e

echo "=== Installing Dante SOCKS5 ==="

if [ "$(id -u)" != "0" ]; then
    echo "Please run as root"
    exit 1
fi

apt update
apt install -y dante-server curl

# 自动获取出口网卡
IFACE=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "$IFACE" ]; then
    echo "Cannot detect network interface"
    exit 1
fi

echo "Network interface: $IFACE"

# 创建用户
USER="socks"
PASS=$(openssl rand -base64 12)

id "$USER" >/dev/null 2>&1 || useradd -m "$USER"

echo "$USER:$PASS" | chpasswd


# 配置 Dante

cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = 1080
external: $IFACE

socksmethod: username

user.privileged: root
user.notprivileged: $USER

client pass {
    from: 0.0.0.0/0
    to: 0.0.0.0/0
}

proxy pass {
    from: 0.0.0.0/0
    to: 0.0.0.0/0
}
EOF


systemctl restart danted
systemctl enable danted


echo
echo "=============================="
echo " SOCKS5 READY"
echo "=============================="
echo "Server : $(curl -s ifconfig.me)"
echo "Port   : 1080"
echo "User   : $USER"
echo "Pass   : $PASS"
echo "=============================="
