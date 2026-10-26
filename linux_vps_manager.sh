#!/usr/bin/env bash
# Linux VPS 管理面板：UFW / SSH / Speedtest / iperf3
# 支持 Debian、Ubuntu；其他发行版尽力通过包管理器安装。
set -o pipefail

APP_NAME="Linux VPS 管理面板"
SSH_PORT_FILE="/etc/ssh/sshd_config.d/00-vps-manager-port.conf"
BACKUP_DIR="/root/vps-manager-backups"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

pause() {
  echo
  read -r -p "按回车键返回菜单..." _
}

have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf '%s (%s)' "${PRETTY_NAME:-Linux}" "${ID:-unknown}"
  else
    uname -s
  fi
}

pkg_install() {
  local packages=("$@")
  if have apt-get; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif have dnf; then
    dnf install -y "${packages[@]}"
  elif have yum; then
    yum install -y "${packages[@]}"
  elif have apk; then
    apk add --no-cache "${packages[@]}"
  elif have pacman; then
    pacman -Sy --noconfirm "${packages[@]}"
  else
    echo "未识别的包管理器，请手动安装：${packages[*]}"
    return 1
  fi
}

ufw_installed() { have ufw; }

ssh_service_type() {
  # 输出 SSH 服务类型与管理方式，兼容 systemd / OpenRC / 非 systemd。
  if have systemctl && systemctl is-active --quiet ssh.socket 2>/dev/null; then
    echo "systemd socket activation (ssh.socket)"
  elif have systemctl && systemctl is-active --quiet ssh.service 2>/dev/null; then
    echo "systemd service (ssh.service)"
  elif have systemctl && systemctl is-active --quiet sshd.service 2>/dev/null; then
    echo "systemd service (sshd.service)"
  elif have rc-service && rc-service sshd status >/dev/null 2>&1; then
    echo "OpenRC (sshd)"
  elif have service && service ssh status >/dev/null 2>&1; then
    echo "service (ssh)"
  elif have service && service sshd status >/dev/null 2>&1; then
    echo "service (sshd)"
  elif have sshd; then
    echo "sshd detected (service manager unknown)"
  else
    echo "SSH server not detected"
  fi
}

get_ssh_ports() {
  # 优先读取 sshd 的有效配置；sshd -T 能解析 Include/Match 等常见配置。
  local ports=""
  if have sshd; then
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu | paste -sd, -)"
  fi

  # 若 sshd -T 不可用，再读取常见配置文件中的 Port 指令。
  if [[ -z "$ports" ]]; then
    local files=()
    [[ -r /etc/ssh/sshd_config ]] && files+=(/etc/ssh/sshd_config)
    if [[ -d /etc/ssh/sshd_config.d ]]; then
      while IFS= read -r -d '' f; do files+=("$f"); done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null | sort -z)
    fi
    if ((${#files[@]})); then
      ports="$(awk '
        /^[[:space:]]*#/ {next}
        tolower($1)=="port" && $2 ~ /^[0-9]+$/ {p=$2}
        END {if (p!="") print p}
      ' "${files[@]}")"
    fi
  fi

  # 最后从监听套接字中识别实际 SSH 端口。
  if [[ -z "$ports" ]] && have ss; then
    ports="$(ss -lntp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); p=a[n]; if (p ~ /^[0-9]+$/) print p}' | sort -nu | paste -sd, -)"
  fi
  printf '%s' "${ports:-22}"
}

get_ssh_port() {
  get_ssh_ports | cut -d, -f1
}

show_status() {
  echo "========== 系统信息 =========="
  echo "系统：$(detect_os)"
  echo "内核：$(uname -r)"
  echo "架构：$(uname -m)"
  echo "SSH 配置端口：$(get_ssh_ports)"
  echo "SSH 服务类型：$(ssh_service_type)"
  if have systemctl; then
    systemctl is-active ssh 2>/dev/null | sed 's/^/SSH 服务：/' || true
    systemctl is-active sshd 2>/dev/null | sed 's/^/SSHD 服务：/' || true
    systemctl is-active ssh.socket 2>/dev/null | sed 's/^/SSH Socket：/' || true
  fi
  if ufw_installed; then
    echo "UFW：$(ufw status 2>/dev/null | head -n1)"
  else
    echo "UFW：未安装"
  fi
  echo
  echo "监听端口（前 30 项）："
  if have ss; then ss -lntup 2>/dev/null | head -n 31; else echo "未找到 ss 命令"; fi
}

install_ufw() {
  if ufw_installed; then
    echo "UFW 已安装。"
  else
    echo "正在安装 UFW..."
    if ! pkg_install ufw; then pause; return; fi
  fi
  if have systemctl; then
    systemctl enable ufw 2>/dev/null || true
  fi
  echo "UFW 安装完成。注意：安装不等于启用。"
  pause
}


parse_port_spec() {
  # 输入形如：80,443,8080-8090,10000-20000；输出逐项规范化后的端口/范围。
  local input="$1" item left right
  local -a items
  input="${input//[[:space:]]/}"
  [[ -n "$input" ]] || { echo "错误：端口列表不能为空。" >&2; return 1; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || { echo "错误：存在空项目，请检查逗号。" >&2; return 1; }
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      left="${BASH_REMATCH[1]}"; right="${BASH_REMATCH[2]}"
      ((left >= 1 && right <= 65535 && left <= right)) || {
        echo "错误：无效端口范围：$item" >&2; return 1;
      }
      printf '%s-%s\n' "$left" "$right"
    elif [[ "$item" =~ ^[0-9]+$ ]]; then
      left="$item"
      ((left >= 1 && left <= 65535)) || {
        echo "错误：端口必须在 1-65535：$item" >&2; return 1;
      }
      printf '%s\n' "$left"
    else
      echo "错误：无法识别的端口项目：$item" >&2
      return 1
    fi
  done
}

apply_port_spec() {
  local spec="$1" proto="$2" action="${3:-allow}"
  local item start end
  local -a items
  mapfile -t items < <(parse_port_spec "$spec") || return 1
  ((${#items[@]} > 0)) || return 1

  # 先完整验证，再逐条应用，避免列表中途遇到非法端口才发现错误。
  for item in "${items[@]}"; do
    if [[ "$item" == *-* ]]; then
      start="${item%-*}"; end="${item#*-}"
      case "$proto" in
        tcp|udp) ufw "$action" "${start}:${end}/${proto}" || return 1 ;;
        both) ufw "$action" "${start}:${end}/tcp" && ufw "$action" "${start}:${end}/udp" || return 1 ;;
      esac
    else
      case "$proto" in
        tcp|udp) ufw "$action" "${item}/${proto}" || return 1 ;;
        both) ufw "$action" "${item}/tcp" && ufw "$action" "${item}/udp" || return 1 ;;
      esac
    fi
  done
}
ufw_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "========== UFW 防火墙管理 =========="
    echo "1. 安装 UFW"
    echo "2. 启用 UFW（会先确认 SSH 端口规则）"
    echo "3. 停用 UFW"
    echo "4. 查看状态/规则"
    echo "5. 放行单个端口"
    echo "6. 放行端口范围"
    echo "7. 批量放行端口（空格分隔）"
    echo "8. 删除规则（按规则编号）"
    echo "9. 设置默认策略（入站拒绝、出站允许）"
    echo "10. 组合端口列表（例如 80,443,8080-8090,10000-20000）"
    echo "0. 返回主菜单"
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_ufw ;;
      2)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        local sshp
        sshp="$(get_ssh_port)"
        echo "检测到 SSH 配置端口：$sshp"
        ufw allow "${sshp}/tcp" || { echo "放行 SSH 端口失败，未启用防火墙。"; pause; continue; }
        read -r -p "确认启用 UFW？远程 VPS 请确保云厂商安全组也放行 SSH 端口 [y/N]：" yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
          ufw default deny incoming && ufw default allow outgoing && ufw --force enable
        else echo "已取消。"; fi
        pause ;;
      3)
        if ufw_installed; then
          read -r -p "确定停用 UFW？[y/N]：" yn
          [[ "$yn" =~ ^[Yy]$ ]] && ufw disable
        else echo "UFW 未安装。"; fi
        pause ;;
      4) if ufw_installed; then ufw status numbered; else echo "UFW 未安装。"; fi; pause ;;
      5)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        read -r -p "端口号（1-65535）：" port
        [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) || { echo "端口无效。"; pause; continue; }
        read -r -p "协议 tcp/udp/both [tcp]：" proto; proto="${proto:-tcp}"
        case "$proto" in
          tcp|udp) ufw allow "${port}/${proto}" ;;
          both) ufw allow "$port/tcp" && ufw allow "$port/udp" ;;
          *) echo "协议无效。" ;;
        esac
        pause ;;
      6)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        read -r -p "起始端口：" start
        read -r -p "结束端口：" end
        [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && ((start>=1 && end<=65535 && start<=end)) || { echo "端口范围无效。"; pause; continue; }
        read -r -p "协议 tcp/udp/both [tcp]：" proto; proto="${proto:-tcp}"
        case "$proto" in
          tcp|udp) ufw allow "${start}:${end}/${proto}" ;;
          both) ufw allow "${start}:${end}/tcp" && ufw allow "${start}:${end}/udp" ;;
          *) echo "协议无效。" ;;
        esac
        pause ;;
      7)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        read -r -p "输入端口号，以空格分隔：" ports
        read -r -p "协议 tcp/udp/both [tcp]：" proto; proto="${proto:-tcp}"
        valid=1
        for port in $ports; do
          if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port<1 || port>65535)); then
            echo "无效端口：$port"; valid=0
          fi
        done
        if ((valid)); then
          for port in $ports; do
            case "$proto" in
              tcp) ufw allow "${port}/tcp" ;;
              udp) ufw allow "${port}/udp" ;;
              both) ufw allow "${port}/tcp" && ufw allow "${port}/udp" ;;
              *) echo "协议无效。"; break ;;
            esac
          done
        fi
        pause ;;
      8)
        if ! ufw_installed; then echo "UFW 未安装。"; pause; continue; fi
        ufw status numbered
        read -r -p "输入要删除的规则编号：" num
        [[ "$num" =~ ^[0-9]+$ ]] && ufw --force delete "$num"
        pause ;;
      9)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        sshp="$(get_ssh_port)"
        ufw allow "${sshp}/tcp" && ufw default deny incoming && ufw default allow outgoing
        echo "已设置默认策略并确保当前 SSH 端口放行。规则生效情况请查看状态。"
        pause ;;
      10)
        if ! ufw_installed; then echo "请先安装 UFW。"; pause; continue; fi
        read -r -p "端口列表（示例 80,443,8080-8090,10000-20000）：" spec
        if ! parse_port_spec "$spec"; then pause; continue; fi
        echo "将放行以下端口/范围："
        parse_port_spec "$spec"
        read -r -p "协议 tcp/udp/both [tcp]：" proto; proto="${proto:-tcp}"
        case "$proto" in
          tcp|udp|both) ;;
          *) echo "协议无效。"; pause; continue ;;
        esac
        read -r -p "确认执行？[y/N]：" yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
          apply_port_spec "$spec" "$proto" allow
        else
          echo "已取消。"
        fi
        pause ;;
      0) return ;;
      *) echo "无效选项。"; pause ;;
    esac
  done
}

restart_ssh_service() {
  if have systemctl; then
    # socket activation must be handled separately; caller guards this case.
    systemctl restart ssh 2>/dev/null && return 0
    systemctl restart sshd 2>/dev/null && return 0
  fi
  if have rc-service; then rc-service sshd restart 2>/dev/null && return 0; fi
  if have service; then
    service ssh restart 2>/dev/null && return 0
    service sshd restart 2>/dev/null && return 0
  fi
  return 1
}

change_ssh_port() {
  echo "当前 SSH 配置端口：$(get_ssh_ports)"
  echo "SSH 服务类型：$(ssh_service_type)"
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    echo "检测到 ssh.socket 正在激活。此模式下端口可能由 socket 配置控制。"
    echo "为避免误配置导致无法登录，本脚本暂不自动修改 socket 模式；请先检查："
    echo "  systemctl cat ssh.socket"
    echo "  systemctl status ssh.socket"
    pause
    return
  fi

  read -r -p "输入新的 SSH 端口（1-65535）：" newport
  [[ "$newport" =~ ^[0-9]+$ ]] && ((newport>=1 && newport<=65535)) || { echo "端口无效。"; pause; return; }
  oldport="$(get_ssh_port)"
  if [[ "$newport" == "$oldport" ]]; then echo "新端口与当前端口相同。"; pause; return; fi
  if have ss && ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "[:.]${newport}$"; then
    echo "警告：端口 $newport 似乎已被监听，请先确认是否冲突。"
    read -r -p "仍然继续？[y/N]：" yn
    [[ "$yn" =~ ^[Yy]$ ]] || { pause; return; }
  fi

  mkdir -p "$BACKUP_DIR"
  cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.$(date +%Y%m%d-%H%M%S).bak"
  mkdir -p /etc/ssh/sshd_config.d

  echo "先放行新端口，避免防火墙阻止连接。"
  if ufw_installed; then ufw allow "${newport}/tcp" || { echo "放行新端口失败，已取消。"; pause; return; }; fi

  # 清除主配置中显式的 Port 行，使用独立 drop-in 文件。
  cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.pre-port-change"
  sed -i -E '/^[[:space:]]*Port[[:space:]]+[0-9]+/d' /etc/ssh/sshd_config
  printf 'Port %s\n' "$newport" > "$SSH_PORT_FILE"
  chmod 600 "$SSH_PORT_FILE"

  if ! sshd -t; then
    echo "SSH 配置检查失败，正在回滚。"
    cp "$BACKUP_DIR/sshd_config.pre-port-change" /etc/ssh/sshd_config
    rm -f "$SSH_PORT_FILE"
    pause
    return
  fi

  if ! restart_ssh_service; then
    echo "SSH 服务重启失败。请保持当前会话，不要退出。"
    echo "配置文件：$SSH_PORT_FILE"
    echo "可尝试恢复：cp '$BACKUP_DIR/sshd_config.pre-port-change' /etc/ssh/sshd_config && rm -f '$SSH_PORT_FILE' && sshd -t && systemctl restart ssh"
    pause
    return
  fi

  echo
  echo "SSH 服务已重启。请保持当前会话，并在另一个终端测试："
  echo "  ssh -p ${newport} 用户名@服务器IP"
  echo "如果新端口无法连接，请不要关闭当前会话。"
  read -r -p "确认新端口已成功登录后，是否删除旧端口 UFW 放行规则？输入 yes 执行：" confirm
  if [[ "$confirm" == "yes" ]] && ufw_installed; then
    ufw --force delete allow "${oldport}/tcp"
    echo "已尝试删除旧端口规则。"
  else
    echo "保留旧端口规则，便于回退。"
  fi
  pause
}

install_speedtest() {
  if have speedtest; then
    echo "Speedtest 已安装："
    speedtest --version 2>/dev/null || true
    pause
    return
  fi
  echo "正在安装 Ookla Speedtest CLI..."
  if have apt-get; then
    apt-get update
    pkg_install curl ca-certificates gnupg
    if ! curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh -o /tmp/ookla-speedtest-repo.sh; then
      echo "下载官方仓库安装脚本失败。"; pause; return
    fi
    if ! bash /tmp/ookla-speedtest-repo.sh; then echo "添加 Ookla 仓库失败。"; pause; return; fi
    if ! apt-get install -y speedtest; then
      echo "安装失败。若系统提示与 speedtest-cli 包冲突，请检查后再处理。"
      pause; return
    fi
  elif have apk; then
    echo "Alpine 仓库中的 Ookla Speedtest CLI 可能不可用。尝试安装 speedtest-cli（Python 版本）。"
    pkg_install py3-pip
    pip3 install --break-system-packages speedtest-cli 2>/dev/null || pip3 install speedtest-cli
  else
    echo "当前发行版未配置 Ookla 官方仓库自动安装。请使用官方安装说明或系统包管理器安装。"
    echo "官方说明：https://www.speedtest.net/apps/cli"
    pause
    return
  fi
  pause
}

run_speedtest() {
  if have speedtest; then
    speedtest
  elif have speedtest-cli; then
    speedtest-cli
  else
    echo "未检测到 Speedtest，请先安装。"
  fi
  pause
}

install_iperf3() {
  if have iperf3; then
    echo "iperf3 已安装。"
  else
    pkg_install iperf3 || { pause; return; }
  fi
  echo "iperf3 安装完成。"
  echo "客户端示例：iperf3 -c 服务器IP"
  echo "服务端示例：iperf3 -s"
  echo "默认服务端端口为 TCP 5201；需要远程测试时请按需放行：ufw allow 5201/tcp"
  pause
}

iperf3_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "========== iperf3 =========="
    echo "1. 安装 iperf3"
    echo "2. 作为客户端测速"
    echo "3. 启动服务端（当前终端运行）"
    echo "4. 后台启动服务端（systemd 临时服务）"
    echo "0. 返回主菜单"
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_iperf3 ;;
      2)
        if ! have iperf3; then echo "请先安装 iperf3。"; pause; continue; fi
        read -r -p "目标服务器地址或域名：" host
        read -r -p "目标端口 [5201]：" port; port="${port:-5201}"
        read -r -p "测试时长秒数 [10]：" duration; duration="${duration:-10}"
        [[ "$port" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]] || { echo "端口或时长无效。"; pause; continue; }
        iperf3 -c "$host" -p "$port" -t "$duration"
        pause ;;
      3)
        if ! have iperf3; then echo "请先安装 iperf3。"; pause; continue; fi
        echo "按 Ctrl+C 停止服务端。"
        iperf3 -s
        pause ;;
      4)
        if ! have iperf3; then echo "请先安装 iperf3。"; pause; continue; fi
        if ! have systemctl; then echo "此功能需要 systemd。"; pause; continue; fi
        cat >/etc/systemd/system/iperf3-temporary.service <<'UNIT'
[Unit]
Description=Temporary iperf3 server
After=network.target
[Service]
ExecStart=/usr/bin/iperf3 -s
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable --now iperf3-temporary.service
        echo "服务端已启动。需要远程访问时，请在防火墙及云安全组放行 TCP 5201。"
        pause ;;
      0) return ;;
      *) echo "无效选项。"; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "======================================"
    echo "        $APP_NAME"
    echo "======================================"
    echo "系统：$(detect_os)"
    echo "SSH 端口：$(get_ssh_ports) | 服务：$(ssh_service_type)"
    echo "UFW：$(ufw_installed && ufw status 2>/dev/null | head -n1 || echo 未安装)"
    echo
    echo "1. 查看系统与服务状态"
    echo "2. UFW 防火墙管理"
    echo "3. 修改 SSH 端口"
    echo "4. 安装 Speedtest"
    echo "5. 运行 Speedtest"
    echo "6. iperf3 管理"
    echo "0. 退出"
    echo
    read -r -p "请输入选项：" choice
    case "$choice" in
      1) show_status; pause ;;
      2) ufw_menu ;;
      3) change_ssh_port ;;
      4) install_speedtest ;;
      5) run_speedtest ;;
      6) iperf3_menu ;;
      0) exit 0 ;;
      *) echo "无效选项。"; pause ;;
    esac
  done
}

main_menu
