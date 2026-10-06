cat > /root/add-ipv6.sh <<'EOF'
#!/bin/bash
set -e

IFACE="eth0"
CONFIG="/etc/network/interfaces.d/50-cloud-init"
DISABLE_CLOUDINIT="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

echo "======================================"
echo " Debian IPv6 自动绑定脚本"
echo "======================================"

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 运行"
    exit 1
fi

# 检查接口
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "错误：找不到网卡 $IFACE"
    exit 1
fi

# 检查配置文件
if [ ! -f "$CONFIG" ]; then
    echo "错误：找不到 $CONFIG"
    exit 1
fi

# 获取第一个全局 IPv6
CURRENT_IPV6=$(ip -6 -o addr show dev "$IFACE" scope global | awk 'NR==1 {print $4}')

if [ -z "$CURRENT_IPV6" ]; then
    echo "错误：$IFACE 没有 IPv6 地址"
    exit 1
fi

# 提取 /64 前缀
PREFIX=$(echo "$CURRENT_IPV6" | cut -d/ -f1 | cut -d: -f1-4)

if [ -z "$PREFIX" ]; then
    echo "错误：无法获取 IPv6 前缀"
    exit 1
fi

# 随机生成后 64 bit
RAND1=$(printf '%04x' $((RANDOM * RANDOM % 65536)))
RAND2=$(printf '%04x' $((RANDOM * RANDOM % 65536)))
RAND3=$(printf '%04x' $((RANDOM * RANDOM % 65536)))
RAND4=$(printf '%04x' $((RANDOM * RANDOM % 65536)))

IPV6="${PREFIX}:${RAND1}:${RAND2}:${RAND3}:${RAND4}"

echo
echo "网卡       : $IFACE"
echo "IPv6 前缀  : ${PREFIX}::/64"
echo "随机 IPv6  : $IPV6"
echo

# 检查是否已经存在
if ip -6 addr show dev "$IFACE" | grep -q "$IPV6"; then
    echo "该 IPv6 已经存在，无需重复添加"
else
    echo "正在绑定 IPv6..."

    ip -6 addr add "${IPV6}/64" dev "$IFACE"

    echo "绑定成功"
fi

# 创建 cloud-init 禁用配置
mkdir -p /etc/cloud/cloud.cfg.d

if [ ! -f "$DISABLE_CLOUDINIT" ]; then
    echo "network: {config: disabled}" > "$DISABLE_CLOUDINIT"
    echo "已禁用 cloud-init 网络自动覆盖"
else
    echo "cloud-init 网络配置已经被禁用"
fi

# 备份 ifupdown 配置
BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$BACKUP"

echo "配置备份：$BACKUP"

# 检查配置中是否已经存在 up 规则
if grep -qF "$IPV6" "$CONFIG"; then
    echo "配置文件中已经存在该 IPv6"
else
    cat >> "$CONFIG" <<EOF2

# Automatically added IPv6
up ip -6 addr add ${IPV6}/64 dev ${IFACE}
down ip -6 addr del ${IPV6}/64 dev ${IFACE}
EOF2

    echo "已写入永久配置"
fi

echo
echo "======================================"
echo " 完成"
echo "======================================"
echo
echo "IPv6：$IPV6"
echo "前缀：${PREFIX}::/64"
echo
echo "当前地址："
ip -6 addr show dev "$IFACE" scope global

echo
echo "测试 IPv6 出口："
ping -6 -I "$IPV6" -c 3 2606:4700:4700::1111

echo
echo "重启后可使用以下命令检查："
echo "ip -6 addr show dev $IFACE"
echo
echo "配置文件：$CONFIG"
echo "备份文件：$BACKUP"
EOF

chmod +x /root/add-ipv6.sh
/root/add-ipv6.sh
