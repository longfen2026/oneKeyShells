#!/usr/bin/env bash
set -euo pipefail

TABLE="mark_dscp"
CHAIN="output"
DST_NET="2409:8000::/20"
DSCP="cs7"
NFT_CONF="/etc/nftables.conf"

echo "========================================"
echo " IPv6 DSCP 自动配置"
echo "========================================"
echo "目标网段 : ${DST_NET}"
echo "DSCP     : ${DSCP} (56)"
echo "接口     : 所有本机 IPv6 出站接口"
echo

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 运行此脚本。"
    exit 1
fi

# 检查 nft
if ! command -v nft >/dev/null 2>&1; then
    echo "[1/6] 安装 nftables..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
else
    echo "[1/6] nftables 已安装。"
fi

echo "[2/6] 创建临时 nftables 配置..."

TMP_CONF="$(mktemp)"

cat > "${TMP_CONF}" <<EOF
table ip6 ${TABLE} {
    chain ${CHAIN} {
        type filter hook output priority filter; policy accept;
        ip6 daddr ${DST_NET} ip6 dscp set ${DSCP}
    }
}
EOF

echo "[3/6] 检查 nftables 配置语法..."

if ! nft -c -f "${TMP_CONF}"; then
    echo "错误：nftables 配置检查失败。"
    rm -f "${TMP_CONF}"
    exit 1
fi

echo "配置语法正确。"

echo "[4/6] 删除旧的 ${TABLE} 表（如果存在）..."

nft delete table ip6 "${TABLE}" 2>/dev/null || true

echo "[5/6] 应用 DSCP 配置..."

nft -f "${TMP_CONF}"

rm -f "${TMP_CONF}"

echo "[6/6] 写入持久化配置..."

# 备份现有配置
if [ -f "${NFT_CONF}" ]; then
    BACKUP="${NFT_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "${NFT_CONF}" "${BACKUP}"
    echo "已备份原配置：${BACKUP}"
fi

# 如果原配置存在其他规则，则保留它们；
# 删除之前由本脚本生成的 mark_dscp 表。
if [ -f "${NFT_CONF}" ]; then
    sed '/^table ip6 mark_dscp {$/,/^}$/d' \
        "${NFT_CONF}" > "${NFT_CONF}.new" || true

    mv "${NFT_CONF}.new" "${NFT_CONF}"
else
    touch "${NFT_CONF}"
fi

cat >> "${NFT_CONF}" <<EOF

# IPv6 DSCP - automatically generated
table ip6 ${TABLE} {
    chain ${CHAIN} {
        type filter hook output priority filter; policy accept;
        ip6 daddr ${DST_NET} ip6 dscp set ${DSCP}
    }
}
EOF

echo
echo "启用 nftables 服务..."

systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

echo
echo "========================================"
echo " 配置完成"
echo "========================================"

echo
echo "当前规则："
nft list table ip6 "${TABLE}"

echo
echo "检查 nftables 服务："
systemctl --no-pager --full status nftables | head -n 15

echo
echo "========================================"
echo " DSCP 配置说明"
echo "========================================"
echo "目的网段 : ${DST_NET}"
echo "DSCP     : CS7"
echo "DSCP 数值: 56"
echo "Traffic Class: 0xE0（ECN=0 时）"
echo
echo "规则只作用于本机 OUTPUT 流量。"
echo "========================================"
