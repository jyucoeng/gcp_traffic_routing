#!/bin/bash

# ==========================================
# 流量监控自动部署脚本 (通用任意平台 / 可选 Telegram 通知)
# 功能：
# 1. 自动获取网卡，只监控出站流量 (TX)
# 2. 运行 check_traffic.sh 时终端显示精确流量，日志保留简略信息
# 3. 每月重置流量并删除旧的监控日志
# 4. 超限后双向封锁 (INPUT + OUTPUT + FORWARD DROP)，仅保留 SSH(入/出双向永放行)/DNS/lo
# 5. oracle 平台自动停用 firewalld / ufw，避免与 iptables 冲突
# 6. TG 通知（可选）：断网前发一条、每月1号恢复发一条
#
# 【配置方式】
# 部署时的全部配置写入 ${CONF_FILE}（即 /etc/netMonitor.conf）。
# TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 不明文保存：部署时用 AES-256 加密
# （密钥在 ${NETMON_KEY}，即 /etc/netMonitor.key，权限 0600）后以 *_ENC 字段写入。
# 运行时脚本用密钥文件解密后使用，密码不落盘、不出现在命令行参数。
#
# 之后修改配置【统一通过子命令，勿直接手改文件】：
#   bash traffic_ctrl.sh edit       # 交互式菜单：改平台/上限/端口/DNS/网卡/TG
#   bash traffic_ctrl.sh set-tg     # 更换 TG（从环境变量 TELEGRAM_BOT_TOKEN/CHAT_ID 读取）
#   bash traffic_ctrl.sh clear-tg   # 停用并清除 TG 凭据
#   bash traffic_ctrl.sh config     # 查看当前配置（TG 凭据以掩码显示）
#
# 平台差异通过 PLATFORM 区分（建议统一小写）：
#   PLATFORM=gcp    -> 上限默认 180GB
#   PLATFORM=oracle -> 上限默认 9TB(9216GB)，并自动停用 firewalld/ufw
#   其他任意标识可用（aws/azure/hetzner/custom...），仅需手动指定 LIMIT：
#     例: PLATFORM=aws LIMIT=1024 bash traffic_ctrl.sh
# ==========================================

# ==========================================
# 部署参数（全部可用环境变量覆盖，未设置时取默认值）
# ==========================================
# 平台标识: 建议全部用小写。
#   内置特殊处理: gcp / oracle
#     - gcp    -> LIMIT 默认 180
#     - oracle -> LIMIT 默认 9216，并自动停用 firewalld/ufw
#   其他任意平台标识也可用（如 aws / azure / hetzner / custom...），
#   仅需手动指定 LIMIT；TG 通知标题会显示对应的平台名。
PLATFORM="${PLATFORM:-gcp}"

# 出站流量上限 (GB)，超过该值触发封网
# 留空时按 PLATFORM 自动设置: gcp=180, oracle=9216；其他平台请务必手动指定
LIMIT="${LIMIT:-}"

# SSH 端口，超限双向封网后仍双向放行的端口 (INPUT 入站握手 + OUTPUT 回包)，保证远程管理不断线。
# 注意: 填 VPS 内部 sshd 实际监听的端口；外部经 NAT/跳板映射的端口与此无关 (NAT 在 VPS 之外, VPS 只见内部端口)。
SSH_PORT="${SSH_PORT:-22}"
# DNS 服务器，封网后允许的 DNS 查询；支持 IPv4/IPv6 混列。
# 留空时自动按地址族选择：IPv4 用 8.8.8.8 8.8.4.4；纯 IPv6 用 Google IPv6 DNS (2001:4860:4860::8888/8844)。
DNS_SERVERS="${DNS_SERVERS:-}"

# ---- Telegram 通知（可选）----
# 部署示例：TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash traffic_ctrl.sh
# 部署后需更换：TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash traffic_ctrl.sh set-tg
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# 运行时配置文件路径（一般无需改动；需共享配置时可重定向）
CONF_FILE="${CONF_FILE:-/etc/netMonitor.conf}"
# TG 凭据加密密钥文件（0600，root-only；丢失后凭据不可恢复，需重新 set-tg）
NETMON_KEY="${NETMON_KEY:-/etc/netMonitor.key}"
# ==========================================

# TG 通知开关：两者均非空才启用
TG_ENABLED=0
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    TG_ENABLED=1
fi

# 判定是否 oracle 平台：平台名包含 oracle/甲骨文（大小写不敏感）即视为 oracle
is_oracle_platform() {
    echo "$PLATFORM" | grep -qiE 'oracle|甲骨文'
}

# 若未手动设置 LIMIT，则按平台取默认值（纯函数，供测试用）
resolve_limit() {
    if [ -n "${LIMIT:-}" ]; then
        echo "$LIMIT"
    elif is_oracle_platform; then
        echo 9216
    else
        echo 180
    fi
}
LIMIT="$(resolve_limit)"

# 按地址族解析 DNS 默认值（纯函数，供测试用；仅当 DNS_SERVERS 为空时调用）
resolve_dns() {
    if [ "$HAS_V4" = "0" ] && [ "$HAS_V6" = "1" ]; then
        echo "2001:4860:4860::8888 2001:4860:4860::8844"
    else
        echo "8.8.8.8 8.8.4.4"
    fi
}

# ==========================================
# 通用工具函数
# ==========================================
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：请使用 root 权限运行此脚本。" >&2
        exit 1
    fi
}

# 生成密钥文件（首次使用时；已存在则复用）
gen_key() {
    if [ ! -s "$NETMON_KEY" ]; then
        mkdir -p "$(dirname "$NETMON_KEY")"
        umask 077
        openssl rand -base64 32 > "$NETMON_KEY"
        chmod 0600 "$NETMON_KEY"
    fi
}

# 加密单个短字符串（用密钥文件，空输入加密为空串）
enc_tg() {
    local s="$1"
    [ -n "$s" ] || { echo ""; return 0; }
    printf '%s' "$s" | openssl enc -aes-256-cbc -pbkdf2 -a -salt -pass file:"$NETMON_KEY" 2>/dev/null
}

# 解密单个字符串（部署脚本侧，供 config 子命令查看用；与运行时脚本逻辑一致）
dec_tg() {
    local enc="$1"
    [ -n "$enc" ] || { echo ""; return 0; }
    [ -r "$NETMON_KEY" ] || { echo ""; return 0; }
    printf '%s\n' "$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"$NETMON_KEY" 2>/dev/null
}

# 掩码函数: 保留前4后4字符，中间用 * 隐藏 (过短则整体隐藏)
mask_mid() {
    local v="$1" n mask keep first
    n="${#v}"
    if [ "$n" -le 4 ]; then
        printf '%s' "${v//?/*}"
        return 0
    fi
    # 掩码数量 = 总数一半，首尾各保留剩余的一半（约暴露一半）
    mask=$(( n / 2 ))
    keep=$(( n - mask ))
    first=$(( (keep + 1) / 2 ))
    printf '%s%s%s' "${v:0:first}" "$(printf '%*s' "$mask" '' | tr ' ' '*')" "${v:$((first - keep))}"
}

# 生成全部运行时配置（部署与 set-tg 共用）
write_conf() {
    umask 077
    cat > "$CONF_FILE" <<EOF
# netMonitor 运行时配置
# 修改配置请用：bash traffic_ctrl.sh edit（交互式菜单）；请勿手改本文件
# TELEGRAM_*_ENC 为 AES-256 加密密文（密钥 ${NETMON_KEY}，权限 0600），请勿手改；
# 更换 TG 凭据也可用：bash traffic_ctrl.sh set-tg
PLATFORM="$PLATFORM"
LIMIT=$LIMIT
SSH_PORT=$SSH_PORT
DNS_SERVERS="$DNS_SERVERS"
HAS_V4=$HAS_V4
HAS_V6=$HAS_V6
TELEGRAM_BOT_TOKEN_ENC="$(enc_tg "$TELEGRAM_BOT_TOKEN")"
TELEGRAM_CHAT_ID_ENC="$(enc_tg "$TELEGRAM_CHAT_ID")"
INTERFACE="$INTERFACE"
EOF
    chmod 0600 "$CONF_FILE"
}

# ---------------- 子命令：set-tg / clear-tg ----------------
# 仅更新 TG 凭据（加密落盘），不影响其余配置，不重装依赖/不动 crontab。
tg_set() {
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署（bash traffic_ctrl.sh）再设置 TG。" >&2
        exit 1
    fi
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "用法：TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash $0 set-tg" >&2
        exit 1
    fi
    # 读取现有配置以保留其余字段
    . "$CONF_FILE"
    INTERFACE="${INTERFACE:-}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"
    gen_key
    write_conf
    echo "TG 凭据已更新（加密写入 ${CONF_FILE}）。"
}

tg_clear() {
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署。" >&2
        exit 1
    fi
    . "$CONF_FILE"
    INTERFACE="${INTERFACE:-}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    gen_key
    write_conf
    echo "TG 凭据已清除（关闭通知）。"
}

# ---------------- 子命令：config ----------------
# 查看当前运行时配置；TG 凭据解密后以掩码显示（保留前4后4，隐藏中间）。
config_show() {
    require_root
    if [ ! -r "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署（bash traffic_ctrl.sh）。" >&2
        exit 1
    fi
    . "$CONF_FILE"
    TELEGRAM_BOT_TOKEN_ENC="${TELEGRAM_BOT_TOKEN_ENC:-}"
    TELEGRAM_CHAT_ID_ENC="${TELEGRAM_CHAT_ID_ENC:-}"
    INTERFACE="${INTERFACE:-}"

    local t c
    t="$(dec_tg "$TELEGRAM_BOT_TOKEN_ENC")"
    c="$(dec_tg "$TELEGRAM_CHAT_ID_ENC")"

    echo "======== netMonitor 当前配置 ========"
    echo "平台         : ${PLATFORM:-gcp}"
    echo "流量上限     : ${LIMIT:-180} GB"
    echo "SSH 端口     : ${SSH_PORT:-22}"
    echo "DNS 服务器   : ${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
    echo "网卡接口     : ${INTERFACE:-}"
    if [ -n "$t" ] && [ -n "$c" ]; then
        echo "TG 通知      : 已启用"
        echo "  BOT TOKEN  : $(mask_mid "$t")  (长度 ${#t})"
        echo "  CHAT ID    : $(mask_mid "$c")  (长度 ${#c})"
    else
        echo "TG 通知      : 未启用"
    fi
    echo "配置文件     : $CONF_FILE (0600)"
    echo "密钥文件     : $NETMON_KEY (0600)"
    echo "====================================="
}

# ---------------- 子命令：edit ----------------
# 交互式菜单修改配置（平台/上限/端口/DNS/网卡/TG），改完统一加密落盘。
config_edit() {
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署（bash traffic_ctrl.sh）。" >&2
        exit 1
    fi
    . "$CONF_FILE"
    TELEGRAM_BOT_TOKEN_ENC="${TELEGRAM_BOT_TOKEN_ENC:-}"
    TELEGRAM_CHAT_ID_ENC="${TELEGRAM_CHAT_ID_ENC:-}"
    INTERFACE="${INTERFACE:-}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"

    # 解密现有 TG 以便编辑后原样回写（不输入即保留）
    local t c
    t="$(dec_tg "$TELEGRAM_BOT_TOKEN_ENC")"
    c="$(dec_tg "$TELEGRAM_CHAT_ID_ENC")"

    while :; do
        echo ""
        echo "======== netMonitor 配置修改菜单 ========"
        echo "  平台 PLATFORM    : ${PLATFORM:-gcp}"
        echo "  流量上限 LIMIT   : ${LIMIT:-180} GB"
        echo "  SSH 端口         : ${SSH_PORT:-22}"
        echo "  DNS 服务器       : ${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
        echo "  网卡接口         : ${INTERFACE:-}"
        echo "  TG 通知          : $([ -n "$t" ] && [ -n "$c" ] && echo "已启用" || echo "未启用")"
        echo "========================================"
        echo " 1) 修改平台         2) 修改流量上限"
        echo " 3) 修改 SSH 端口    4) 修改 DNS 服务器"
        echo " 5) 修改网卡接口     6) 修改 TG 凭据"
        echo " 7) 清空 TG 凭据     8) 保存并退出"
        echo " 0) 不保存退出"
        echo "========================================"
        printf "请选择: "
        read -r opt || break

        case "$opt" in
            1)
                printf "新平台(建议小写，如 gcp/oracle/aws/custom) [${PLATFORM:-gcp}]: "; read -r v
                [ -n "$v" ] && PLATFORM="$v"
                ;;
            2)
                printf "新上限 GB [${LIMIT:-180}]: "; read -r v
                [ -n "$v" ] && LIMIT="$v"
                ;;
            3)
                printf "新 SSH 端口 [${SSH_PORT:-22}]: "; read -r v
                [ -n "$v" ] && SSH_PORT="$v"
                ;;
            4)
                printf "新 DNS 服务器(空格分隔) [${DNS_SERVERS:-8.8.8.8 8.8.4.4}]: "; read -r v
                [ -n "$v" ] && DNS_SERVERS="$v"
                ;;
            5)
                printf "新网卡接口 [${INTERFACE:-}]: "; read -r v
                [ -n "$v" ] && INTERFACE="$v"
                ;;
            6)
                printf "新 Bot Token (留空保持不变): "; read -rs t2; echo
                printf "新 Chat ID (留空保持不变): "; read -rs c2; echo
                [ -n "$t2" ] && t="$t2"
                [ -n "$c2" ] && c="$c2"
                ;;
            7)
                t=""
                c=""
                echo "-> TG 凭据已清空"
                ;;
            8)
                TELEGRAM_BOT_TOKEN="$t"
                TELEGRAM_CHAT_ID="$c"
                gen_key
                write_conf
                echo "-> 配置已保存（加密写入 ${CONF_FILE}）。"
                break
                ;;
            0)
                echo "-> 已取消，未做任何修改。"
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# ---------------- 入口分派 ----------------
case "${1:-}" in
    set-tg)
        tg_set
        exit 0
        ;;
    clear-tg)
        tg_clear
        exit 0
        ;;
    config)
        config_show
        exit 0
        ;;
    edit)
        config_edit
        exit 0
        ;;
esac

# ==========================================
# 以下为完整部署流程
# ==========================================

# 测试模式：仅 source 函数定义，不执行部署/子命令（供 tests/smoke-netmon.sh）
if [ "${NETMON_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

require_root

# 0. 发行版 / 服务管理器 / 包管理器 探测
#    支持 debian/ubuntu (apt+systemd) 与 alpine (apk+openrc)
OS=""
PKG_UPDATE=""
PKG_INSTALL=""
SVC_MGR=""
if [ -f /etc/alpine-release ]; then
    OS=alpine
elif [ -f /etc/debian_version ] || command -v apt-get >/dev/null 2>&1; then
    OS=debian
else
    echo "错误：无法识别的发行版，本脚本支持 debian/ubuntu/alpine。" >&2
    exit 1
fi
echo "--> 检测到操作系统: $OS"

# 1. 自动获取默认网卡名称（先 IPv4 默认路由，失败则回退 IPv6）
INTERFACE=$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -6 route 2>/dev/null | grep '^default' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)
fi

if [ -z "$INTERFACE" ]; then
    echo "错误：无法自动检测到网卡名称，请手动设置环境变量 INTERFACE。"
    exit 1
fi

# 地址族探测：IPv4 / IPv6 是否可达
HAS_V4=0
HAS_V6=0
ip -4 route 2>/dev/null | grep -q '^default' && HAS_V4=1
ip -6 route 2>/dev/null | grep -q '^default' && HAS_V6=1

# DNS 默认值：按地址族自动选择（用户未显式指定时）
if [ -z "$DNS_SERVERS" ]; then
    DNS_SERVERS="$(resolve_dns)"
fi

echo "--> 检测到当前主网卡为: $INTERFACE (IPv4=$HAS_V4 IPv6=$HAS_V6)"

# 2. 安装依赖工具 (curl/openssl 恒装：改配置启用 TG 后无需重装依赖)
#    流量统计由 netstat.sh 直接读 /proc/net/dev 完成，不再需要 vnstat/vnstatd。
echo "--> 正在更新软件源并安装工具..."
if [ "$OS" = "alpine" ]; then
    apk update
    # 确保 community 仓库已启用 (iptables 等位于 community；部分精简镜像仅开 main)
    if ! grep -qE '^[^#]*/community[[:space:]]*$' /etc/apk/repositories 2>/dev/null; then
        if grep -qE '^[^#]*/main[[:space:]]*$' /etc/apk/repositories 2>/dev/null; then
            grep -E '^[^#]*/main[[:space:]]*$' /etc/apk/repositories \
                | sed 's#/main[[:space:]]*$#/community#' >> /etc/apk/repositories
            echo "    community 仓库已启用。"
            apk update
        fi
    fi
    # bash: 主脚本及生成的子脚本均为 bash 语法；iproute2: busybox ip 功能不全
    apk add --no-cache bc curl openssl iptables iptables-openrc \
        ip6tables ip6tables-openrc tzdata bash iproute2 \
        || { echo "--> apk 安装失败，重试一次 (启用 community 后重新更新源)..."; \
             apk update && apk add --no-cache bc curl openssl \
                iptables iptables-openrc ip6tables ip6tables-openrc tzdata bash iproute2; }
    # 逐个校验关键工具是否就绪，缺失则明确报错
    MISSING=""
    for _t in iptables ip6tables bc curl openssl bash; do
        command -v "$_t" >/dev/null 2>&1 || MISSING="$MISSING $_t"
    done
    if [ -n "$MISSING" ]; then
        echo "错误：以下工具安装失败:$MISSING" >&2
        echo "提示：请检查 /etc/apk/repositories 源可用性，或手动执行:" >&2
        echo "  apk add --no-cache bc curl openssl iptables iptables-openrc ip6tables ip6tables-openrc tzdata bash iproute2" >&2
        exit 1
    fi
    # alpine 无 systemd，服务管理用 openrc / rc-service
    SVC_MGR=openrc
else
    apt-get update -y
    apt-get install bc curl openssl iptables ip6tables -y \
        || apt-get install -f -y
    # 逐个校验关键工具是否就绪，缺失则明确报错
    MISSING=""
    for _t in bc curl openssl iptables ip6tables; do
        command -v "$_t" >/dev/null 2>&1 || MISSING="$MISSING $_t"
    done
    if [ -n "$MISSING" ]; then
        echo "错误：以下工具安装失败:$MISSING" >&2
        echo "提示：请手动执行: apt-get update && apt-get install bc curl openssl iptables ip6tables" >&2
        exit 1
    fi
    SVC_MGR=systemd
fi

# 2.5 停用 firewalld / ufw (仅 oracle 平台 + systemd，避免与 iptables 规则冲突)
if is_oracle_platform && [ "$SVC_MGR" = "systemd" ]; then
    echo "--> 检查并停用 firewalld / ufw..."
    # 停用 firewalld (RHEL 系)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld
        systemctl disable firewalld
        echo "    firewalld 已停用。"
    elif systemctl list-unit-files | grep -q '^firewalld.service'; then
        systemctl disable firewalld 2>/dev/null
    fi
    # 停用 ufw (Ubuntu/Debian 系)
    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1
        systemctl disable ufw 2>/dev/null
        echo "    ufw 已停用。"
    fi
    # 注意: 不停用也不再清空现有 iptables 规则，避免影响其他程序
fi

# 3. 生成独立流量统计脚本 (/root/netstat.sh)
#    算法与哪吒探针(nezha)一致：直接读 /proc/net/dev，排除虚拟网卡(lo/docker/veth/br-等)，
#    对剩余全部物理网卡的 TX 求和作为"当前出站累计"；通过与上次快照求差得到增量，
#    累加到当月累计（快照回绕/服务器重启时增量归零重新累计），彻底摆脱对 vnstatd 的依赖。
#    供下方 heredoc 展开的绝对路径（check/reset 内 get_monthly_tx 调用统一用此变量）
NETSTAT_BIN="/root/netstat.sh"
echo "--> 生成独立流量统计脚本 /root/netstat.sh..."
cat > /root/netstat.sh <<'NETSTAT'
#!/bin/bash
# netstat.sh - 独立出站流量统计 (nezha 式 /proc/net/dev + 月度增量)
# 用法:
#   /root/netstat.sh            输出当月累计出站字节 (纯数字)
#   /root/netstat.sh --reset    清零当月累计 (每月1号由 reset_network.sh 调用)
#   /root/netstat.sh --current  输出当前网卡累计快照 (调试用)
#   两种用法均会更新/持久化快照。状态文件: /var/lib/traffic_monitor/netcount

set -u
STATE_DIR="/var/lib/traffic_monitor"
COUNT_FILE="$STATE_DIR/netcount"
CUR_MONTH=$(date '+%Y-%m')

# 排除的虚拟网卡标识 (与 nezha 过滤规则对齐)
is_virtual() {
    local n="$1"
    case "$n" in
        lo|docker*|veth*|br-*|virbr*|tun*|tap*|vbox*|dummy*) return 0 ;;
        *) return 1 ;;
    esac
}

# 读 /proc/net/dev, 对所有"非虚拟"网卡的 TX (第 10 列) 求和
current_tx() {
    awk '
        /^[[:space:]]*[a-zA-Z0-9_@.-]+:/ {
            iface=$1; sub(/:/,"",iface)
            if (iface=="lo" || iface ~ /^docker/ || iface ~ /^veth/ || iface ~ /^br-/ \
                || iface ~ /^virbr/ || iface ~ /^tun/ || iface ~ /^tap/ || iface ~ /^vbox/ \
                || iface ~ /^dummy/) next
            sum += $10
        }
        END { print sum+0 }
    ' /proc/net/dev
}

mkdir -p "$STATE_DIR"
CUR=$(current_tx)

if [ "${1:-}" = "--current" ]; then
    echo "$CUR"
    exit 0
fi

# 读取上次状态
LAST=0; MONTH_TX=0; MONTH=""
[ -f "$COUNT_FILE" ] && . "$COUNT_FILE"

# 跨月: 清零当月累计 (新计费周期), 快照保留为下次 delta 基准
if [ "$MONTH" != "$CUR_MONTH" ]; then
    MONTH_TX=0
    MONTH="$CUR_MONTH"
fi

if [ "${1:-}" = "--reset" ]; then
    MONTH_TX=0
    MONTH="$CUR_MONTH"
    LAST=$CUR
    cat > "$COUNT_FILE" <<EOF
MONTH=$MONTH
MONTH_TX=$MONTH_TX
LAST=$LAST
EOF
    echo "$MONTH_TX"
    exit 0
fi

# 求增量: 快照回绕(重启)时 delta 归零重计, 与 nezha min() 语义一致
if [ "$LAST" -eq 0 ] || [ "$CUR" -lt "$LAST" ]; then
    DELTA=$CUR
else
    DELTA=$(( CUR - LAST ))
fi
MONTH_TX=$(( MONTH_TX + DELTA ))
LAST=$CUR

cat > "$COUNT_FILE" <<EOF
MONTH=$MONTH
MONTH_TX=$MONTH_TX
LAST=$LAST
EOF

echo "$MONTH_TX"
NETSTAT
chmod +x /root/netstat.sh
# 立即初始化快照 (--reset：当月累计=0、快照=当前累计；此后每5分钟增量累计)
/root/netstat.sh --reset >/dev/null 2>&1 || true
echo "--> 流量统计脚本已生成并初始化 (独立于 vnstat)。"

# 3.5 生成运行时配置文件与密钥
gen_key
write_conf
echo "--> 运行时配置已写入 ${CONF_FILE}（密钥 ${NETMON_KEY}，TG 凭据已加密）。"

# 4. 生成监控脚本 (/root/check_traffic.sh)
#    配置统一从 CONF_FILE 读取（改配置不改脚本）。
echo "--> 生成监控脚本 /root/check_traffic.sh..."
cat > /root/check_traffic.sh <<EOF
#!/bin/bash

# 强制使用标准区域设置
export LC_ALL=C

# 配置来源：改 /etc/netMonitor.conf 即生效（无需重部署）
CONF_FILE="$CONF_FILE"
NETMON_KEY="$NETMON_KEY"
LOG_FILE="/var/log/traffic_monitor.log"
STATE_FILE="/var/lib/traffic_monitor/state"

# 读取运行时配置
if [ -r "\$CONF_FILE" ]; then
    . "\$CONF_FILE"
else
    echo "错误：缺少配置文件 \$CONF_FILE" >&2
    exit 1
fi

# 解密 TG 凭据（密文 AES-256 -> 明文，仅内存中使用）
dec_tg() {
    local enc="\$1"
    [ -n "\$enc" ] || { echo ""; return 0; }
    [ -r "\$NETMON_KEY" ] || { echo ""; return 0; }
    printf '%s\\n' "\$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"\$NETMON_KEY" 2>/dev/null
}

TELEGRAM_BOT_TOKEN="\$(dec_tg "\$TELEGRAM_BOT_TOKEN_ENC")"
TELEGRAM_CHAT_ID="\$(dec_tg "\$TELEGRAM_CHAT_ID_ENC")"

# 为变量提供兜底默认（配置缺失某项时）
PLATFORM="\${PLATFORM:-gcp}"
SSH_PORT="\${SSH_PORT:-22}"
DNS_SERVERS="\${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
INTERFACE="\${INTERFACE:-}"
# 地址族标记：缺失时按命令可用性兜底
HAS_V4="\${HAS_V4:-1}"
HAS_V6="\${HAS_V6:-1}"
command -v iptables  >/dev/null 2>&1 || HAS_V4=0
command -v ip6tables >/dev/null 2>&1 || HAS_V6=0

[ -n "\$INTERFACE" ] || { echo "错误：配置中缺少 INTERFACE" >&2; exit 1; }
[ -n "\$LIMIT" ] || LIMIT=180

# TG 通知开关 (两者均非空才启用；配置未填 TG 则恒为 0)
TG_ON=0
if [ -n "\$TELEGRAM_BOT_TOKEN" ] && [ -n "\$TELEGRAM_CHAT_ID" ]; then
    TG_ON=1
fi

# 日志记录函数 (保持原格式)
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# 权限检查
if [ "\$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限"
    exit 1
fi

# oracle 平台判定：平台名包含 oracle/甲骨文（大小写不敏感）
is_oracle_platform() {
    echo "\$PLATFORM" | grep -qiE 'oracle|甲骨文'
}

# oracle 平台: 每次检查前确认 firewalld / ufw 未启用，否则停用
if is_oracle_platform; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld 2>/dev/null
        log "运行时停用了 firewalld。"
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'active'; then
        ufw --force disable >/dev/null 2>&1
        log "运行时停用了 ufw。"
    fi
fi

# ==========================================
# 工具函数：获取本机公网 IP 并打码 + IPv4/IPv6 兼容
# IPv4 打码: 152.69.206.146 -> 152.69.***.146
# IPv6 打码: 2400:3200::1 -> 2400:****::1 (保留首尾一组块)
# ==========================================
mask_ip() {
    local ip="$1"
    if [[ "$ip" == *:* ]]; then
        # IPv6: 保留第一段与最后一段(含 ::)，中间掩码
        echo "$ip" | sed -E 's/^([0-9a-fA-F:]*::).*/\1****/' | head -n1
    else
        echo "$ip" | awk -F. 'NF==4 {print $1"."$2".***."$4; exit} {print $ip}'
    fi
}

get_ip_and_loc() {
    local geo ip city cc loc masked
    geo=""
    # 优先 ip-api.com (IPv4 定位)；纯 IPv6 或失败时走 ipwho.is (来源地址族自适应, 支持 v6)
    if [ "\$HAS_V4" = "1" ]; then
        for _try in 1 2 3; do
            geo=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null)
            [ -n "\$geo" ] && break
            sleep 2
        done
    fi
    # ip-api 未取到(纯IPv6/超时/被墙)时用 ipwho.is 兜底；ip-api 是 v4 来源，ipwho 是 v6 来源
    if [ -z "\$geo" ]; then
        if [ "\$HAS_V6" = "1" ]; then
            geo=\$(curl -6 -s --max-time 5 "https://ipwho.is/" 2>/dev/null)
        else
            geo=\$(curl -s --max-time 5 "https://ipwho.is/" 2>/dev/null)
        fi
    fi
    # ip-api 字段: query/cc/city; ipwho 字段: ip/country_code/city
    ip=\$(echo "\$geo" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
    [ -z "\$ip" ] && ip=\$(echo "\$geo" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')
    city=\$(echo "\$geo" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    cc=\$(echo "\$geo" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
    [ -z "\$cc" ] && cc=\$(echo "\$geo" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')

    # 仍未取到 IP 时按地址族用 ipify 后备 (支持 v4/v6)
    if [ -z "\$ip" ]; then
        if [ "\$HAS_V6" = "1" ]; then
            ip=\$(curl -6 -s --max-time 5 "https://api64.ipify.org" 2>/dev/null)
        fi
        [ -z "\$ip" ] && ip=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi
    # 外部查询全部失败时 (如封网断外网) 回退用本机网卡地址, 保证 IP 不至于空白
    if [ -z "\$ip" ]; then
        if [ "\$HAS_V4" = "1" ]; then
            ip=\$(ip -4 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
        fi
        [ -z "\$ip" ] && ip=\$(ip -6 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
    fi

    masked="\$ip"

    # 定位降级: 城市-国家 / 国家 / unknown
    local loc
    if [ -n "\$city" ] && [ -n "\$cc" ]; then
        loc="\${city}-\${cc}"          # 例: Osaka-JP
    elif [ -n "\$cc" ]; then
        loc="\$cc"                      # 例: JP
    else
        loc="unknown"
    fi

    # 输出: masked|loc|ip  (消费端用 IFS='|' read 拆分)
    echo "\${masked}|\${loc}|\${ip}"
}

# ==========================================
# 工具函数：发送 Telegram 通知 (TG 未启用时不动作)
# ==========================================
tg_send() {
    [ "\$TG_ON" = "1" ] || return 0
    local msg="\$1"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=\${msg}" >/dev/null 2>&1
}

# ==========================================
# 获取当月累计出站流量 (返回原始字节数)
# 数据来源: 独立统计脚本 /root/netstat.sh (nezha 式 /proc/net/dev + 月度增量)
# 注意: 调用 netstat.sh 本身就是一次"采样"(其内部会推进快照计算增量),
#       必须只调用一次并把结果复用, 避免同一 cron 周期多次采样导致累计翻倍。
# ==========================================
NETSTAT_BIN="/root/netstat.sh"
get_monthly_tx() {
    local month_tx
    month_tx=\$("$NETSTAT_BIN" 2>/dev/null)
    if [ -z "\$month_tx" ] || ! [[ "\$month_tx" =~ ^[0-9]+$ ]]; then
        month_tx=0
    fi
    echo "\$month_tx"
}

# ==========================================
# 流量格式化: 按 MB -> GB -> TB 层级递进
# 输入: 字节数  输出: 如 512.00MB / 123.45GB / 1.23TB
# 规则: <1GB 用 MB; 1GB~1024GB 用 GB; >=1024GB 用 TB
# ==========================================
format_traffic() {
    local bytes b
    bytes="\$1"
    case "\$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    b=\$(echo "scale=2; \$bytes / 1073741824" | bc)   # 换算成 GB
    if [ \$(echo "\$b < 1" | bc) -eq 1 ]; then
        # 不足 1GB -> MB
        echo "\$(echo "scale=2; \$bytes / 1048576" | bc)MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        # 1GB ~ 1024GB -> GB
        echo "\${b}GB"
    else
        # >= 1024GB (1TB) -> TB
        echo "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)TB"
    fi
}

# ==========================================
# 工具函数：判定 CPU 类型 (AMD / ARM) —— 仅 oracle 平台需要
# AMD 判定: 型号/架构含 AMD/EPYC; ARM 判定: 架构为 aarch64/arm
# ==========================================
get_cpu_type() {
    local arch ctype
    arch=\$(uname -m)
    ctype=\$(lscpu 2>/dev/null | awk -F: '/^Vendor ID|^型号名称|^Model name/ {print \$2}' | head -n1)
    if [[ "\$arch" == aarch64 || "\$arch" == arm* ]]; then
        echo "ARM"
    elif echo "\$arch \$ctype" | grep -qi "amd\|epyc"; then
        echo "AMD"
    else
        echo "AMD"
    fi
}

# ==========================================
# 获取当月累计出站流量 (字节)
# 由独立统计脚本 netstat.sh 计算 (nezha 式 /proc/net/dev + 月度增量)
# ==========================================
TX_BYTES=\$("$NETSTAT_BIN" 2>/dev/null)

# 如果获取失败或为空，默认为 0 (netstat.sh 正常输出纯数字; 任何异常归 0)
if [[ -z "\$TX_BYTES" ]] || ! [[ "\$TX_BYTES" =~ ^[0-9]+$ ]]; then
    TX_BYTES=0
fi

# 将字节转换为 GB (1 GB = 1073741824 Bytes)
TX_GB=\$(echo "scale=2; \$TX_BYTES / 1073741824" | bc)

# ==========================================
# 1. 终端直接输出 (显示精确数值)
# ==========================================
echo "========================================"
echo " 网卡接口    : \$INTERFACE"
echo " 当前时间    : \$(date '+%Y-%m-%d %H:%M:%S')"
echo " 精确出站(TX): \$TX_BYTES Bytes"
echo " 换算出站(TX): \$TX_GB GB"
echo " 流量上限    : \$LIMIT GB"
echo "========================================"

# ==========================================
# 2. 日志记录与限制逻辑
# ==========================================

log "当前出站流量: \$TX_GB GB (限制: \$LIMIT GB)"

# 读取当月状态 (默认 normal)
CUR_MONTH=\$(date '+%Y-%m')
[ -f "\$STATE_FILE" ] && . "\$STATE_FILE"
[ -z "\$STATE" ] && STATE=normal
[ -z "\$MONTH" ] && MONTH="\$CUR_MONTH"
# 若跨月，重置到普通状态 (新一轮计费周期)
if [ "\$MONTH" != "\$CUR_MONTH" ]; then
    STATE=normal
    MONTH="\$CUR_MONTH"
    BLOCKED_TIME=""
    BLOCKED_TX=""
    RESTORED_TIME=""
fi

# 保存当月状态到文件
save_state() {
    mkdir -p "\$(dirname "\$STATE_FILE")"
    cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME="\$BLOCKED_TIME"
BLOCKED_TX="\$BLOCKED_TX"
RESTORED_TIME="\$RESTORED_TIME"
STATE_EOF
}

# 检查是否超限 (用字节级精度比较, 支持 GB 小数上限如 0.001=1MB, 避免 TX_GB 浮点取整误判)
LIMIT_BYTES=\$(echo "scale=0; \$LIMIT * 1073741824 / 1" | bc)
if [ \$(echo "\$TX_BYTES >= \$LIMIT_BYTES" | bc) -eq 1 ]; then
    echo "状态: [警告] 流量已超限，正在禁止出站..."
    log "警告：流量超出限制！正在执行封网策略 (双向封锁)..."

    # ---- 仅当本次由正常转为超限时才发送通知 (同一事件周期只发一次) ----
    if [ "\$STATE" != "blocked" ]; then
        STATE=blocked
        BLOCKED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
        BLOCKED_TX="\$TX_BYTES"
        save_state

        # 超限时发送 TG 通知 (TG 启用时)
        if [ "\$TG_ON" = "1" ]; then
            IFS='|' read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
            RUN_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
            MONTH_TX=\$TX_BYTES
            # CPU 行 (仅 oracle 显示)
            CPU_LINE=""
            if is_oracle_platform; then
                CPU_LINE="
🌐 CPU: \$(get_cpu_type)"
            fi

            # 组装通知文本 (oracle 时含 CPU 行)
TG_MSG="🎮 \$PLATFORM 流量报告（流量超限通知）

🌐 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$RUN_TIME
📚 网络状态: 正常 ---> 超限(双向封网)
🌐 本月流量: \$(format_traffic "\$MONTH_TX") / 上限: \$LIMIT GB\${CPU_LINE}"

            tg_send "\$TG_MSG"
            log "已发送流量超限 TG 通知。"
        fi
    else
        echo "    (本周期已发送超限通知，跳过。)"
        log "本周期已发送超限通知，跳过。"
    fi

    # ---- 封禁策略 (双向封锁: INPUT + OUTPUT + FORWARD, 仅放行 SSH/DNS/lo) ----
    # 支持 IPv4 + IPv6：按 HAS_V4/HAS_V6 分别操作 iptables / ip6tables；
    # DNS 服务器按地址族分流；ICMP 协议 v4=icmp / v6=ipv6-icmp。
    # 不改变全局默认策略(-P)、不全局清空(-F/-X)，只操作自家 TRAFFIC_BLOCKED 链。
    # SSH 双向按方向匹配: INPUT 放行目标 dport (入站握手), OUTPUT 放行源 sport (SSH 回包)，
    # 即使外部经 NAT/跳板映射端口，VPS 只见 sshd 内部端口，填内部端口即可保证不锁死。
    apply_fw() {
        local FW="\$1" ICMP_PROTO="\$2"
        # 创建或复用自家链 (已存在则清空重建)
        "\$FW" -N TRAFFIC_BLOCKED 2>/dev/null || "\$FW" -F TRAFFIC_BLOCKED

        # 放行已建立的连接 (关键: 确保封网瞬间不打断当前 SSH 会话)
        "\$FW" -A TRAFFIC_BLOCKED -m state --state ESTABLISHED,RELATED -j ACCEPT
        # 放行 SSH 管理端口 (双向: INPUT 入站握手 + OUTPUT 回包; 覆盖新 SSH 会话)
        "\$FW" -A TRAFFIC_BLOCKED -p tcp --dport "\$SSH_PORT" -j ACCEPT
        "\$FW" -A TRAFFIC_BLOCKED -p tcp --sport "\$SSH_PORT" -j ACCEPT
        # 放行 DNS 查询 (按地址族匹配)
        for DNS in \$DNS_SERVERS; do
            case "\$DNS" in
                *:*) [ "\$FW" = "ip6tables" ] || continue ;;
                *)   [ "\$FW" = "iptables" ] || continue ;;
            esac
            "\$FW" -A TRAFFIC_BLOCKED -p udp --dport 53 -d "\$DNS" -j ACCEPT
            "\$FW" -A TRAFFIC_BLOCKED -p tcp --dport 53 -d "\$DNS" -j ACCEPT
        done
        # 放行 ICMP / ICMPv6 (ping / NDP 邻居发现, IPv6 必需)
        "\$FW" -A TRAFFIC_BLOCKED -p "\$ICMP_PROTO" -j ACCEPT
        # 放行 loopback (入/出)
        "\$FW" -A TRAFFIC_BLOCKED -i lo -j ACCEPT
        "\$FW" -A TRAFFIC_BLOCKED -o lo -j ACCEPT
        # 链内兜底 DROP: 其余流量在此终结，不回到主链(不影响其他规则)
        "\$FW" -A TRAFFIC_BLOCKED -j DROP

        # 在三条主链最顶部各插入一条跳转到 TRAFFIC_BLOCKED (全局封锁)
        # 用 -I 1 插到最前，确保封网生效；不动各链已有的其他规则与默认策略
        "\$FW" -I INPUT   1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
        "\$FW" -I OUTPUT  1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
        "\$FW" -I FORWARD 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
    }
    [ "\$HAS_V4" = "1" ] && command -v iptables  >/dev/null 2>&1 && apply_fw iptables  icmp
    [ "\$HAS_V6" = "1" ] && command -v ip6tables >/dev/null 2>&1 && apply_fw ip6tables ipv6-icmp

    log "网络已限制 (TRAFFIC_BLOCKED 双向封锁，仅保留 SSH / DNS / lo)。"
else
    echo "状态: [正常] 流量未超限。"

    # 若曾在超限状态，但当前流量已回落则状态归位 normal (不发恢复通知，恢复通知由 reset 触发)
    if [ "\$STATE" = "blocked" ]; then
        STATE=normal
        save_state
        log "检测到流量回落，状态恢复正常。"
    else
        log "流量正常。"
    fi
fi
EOF

# 5. 生成重置脚本 (/root/reset_network.sh)
#    配置同样从 CONF_FILE 读取。
echo "--> 生成重置脚本 /root/reset_network.sh..."
cat > /root/reset_network.sh <<EOF
#!/bin/bash

CONF_FILE="$CONF_FILE"
NETMON_KEY="$NETMON_KEY"
RESET_LOG="/var/log/network_reset.log"
TRAFFIC_LOG="/var/log/traffic_monitor.log"
STATE_FILE="/var/lib/traffic_monitor/state"

# 读取运行时配置
if [ -r "\$CONF_FILE" ]; then
    . "\$CONF_FILE"
else
    echo "错误：缺少配置文件 \$CONF_FILE" >&2
    exit 1
fi

# 解密 TG 凭据
dec_tg() {
    local enc="\$1"
    [ -n "\$enc" ] || { echo ""; return 0; }
    [ -r "\$NETMON_KEY" ] || { echo ""; return 0; }
    printf '%s\\n' "\$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"\$NETMON_KEY" 2>/dev/null
}

TELEGRAM_BOT_TOKEN="\$(dec_tg "\$TELEGRAM_BOT_TOKEN_ENC")"
TELEGRAM_CHAT_ID="\$(dec_tg "\$TELEGRAM_CHAT_ID_ENC")"

# 变量兜底默认（防止配置缺失某项）
PLATFORM="\${PLATFORM:-gcp}"
INTERFACE="\${INTERFACE:-}"
[ -n "\$INTERFACE" ] || { echo "错误：配置中缺少 INTERFACE" >&2; exit 1; }
LIMIT="\${LIMIT:-180}"
DNS_SERVERS="\${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
# 地址族标记：缺失时按命令可用性兜底
HAS_V4="\${HAS_V4:-1}"
HAS_V6="\${HAS_V6:-1}"
command -v iptables  >/dev/null 2>&1 || HAS_V4=0
command -v ip6tables >/dev/null 2>&1 || HAS_V6=0

# TG 通知开关 (两者均非空才启用)
TG_ON=0
if [ -n "\$TELEGRAM_BOT_TOKEN" ] && [ -n "\$TELEGRAM_CHAT_ID" ]; then
    TG_ON=1
fi

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$RESET_LOG"
}

# 发送 Telegram 通知 (TG 未启用时不动作)
tg_send() {
    [ "\$TG_ON" = "1" ] || return 0
    local msg="\$1"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=\${msg}" >/dev/null 2>&1
}

# 获取本机公网 IP 并打码 + IPv4/IPv6 兼容
mask_ip() {
    local ip="$1"
    if [[ "$ip" == *:* ]]; then
        echo "$ip" | sed -E 's/^([0-9a-fA-F:]*::).*/\1****/' | head -n1
    else
        echo "$ip" | awk -F. 'NF==4 {print $1"."$2".***."$4; exit} {print $ip}'
    fi
}

get_ip_and_loc() {
    local geo ip city cc loc masked
    geo=""
    # 优先 ip-api.com (IPv4 定位)；纯 IPv6 或失败时走 ipwho.is (来源地址族自适应, 支持 v6)
    if [ "\$HAS_V4" = "1" ]; then
        for _try in 1 2 3; do
            geo=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null)
            [ -n "\$geo" ] && break
            sleep 2
        done
    fi
    # ip-api 未取到(纯IPv6/超时/被墙)时用 ipwho.is 兜底
    if [ -z "\$geo" ]; then
        if [ "\$HAS_V6" = "1" ]; then
            geo=\$(curl -6 -s --max-time 5 "https://ipwho.is/" 2>/dev/null)
        else
            geo=\$(curl -s --max-time 5 "https://ipwho.is/" 2>/dev/null)
        fi
    fi
    # ip-api 字段: query/cc/city; ipwho 字段: ip/country_code/city
    ip=\$(echo "\$geo" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
    [ -z "\$ip" ] && ip=\$(echo "\$geo" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')
    city=\$(echo "\$geo" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    cc=\$(echo "\$geo" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
    [ -z "\$cc" ] && cc=\$(echo "\$geo" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')
    if [ -z "\$ip" ]; then
        if [ "\$HAS_V6" = "1" ]; then
            ip=\$(curl -6 -s --max-time 5 "https://api64.ipify.org" 2>/dev/null)
        fi
        [ -z "\$ip" ] && ip=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi
    # 外部查询全部失败时 (如封网断外网) 回退用本机网卡地址, 保证 IP 不至于空白
    if [ -z "\$ip" ]; then
        if [ "\$HAS_V4" = "1" ]; then
            ip=\$(ip -4 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
        fi
        [ -z "\$ip" ] && ip=\$(ip -6 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
    fi
    masked="\$ip"
    local loc
    if [ -n "\$city" ] && [ -n "\$cc" ]; then
        loc="\${city}-\${cc}"
    elif [ -n "\$cc" ]; then
        loc="\$cc"
    else
        loc="unknown"
    fi
    # 输出: masked|loc|ip  (消费端用 IFS='|' read 拆分)
    echo "\${masked}|\${loc}|\${ip}"
}

# 获取当月累计出站流量 (返回原始字节数)
# 数据来源: 独立统计脚本 /root/netstat.sh (nezha 式 /proc/net/dev + 月度增量)
# 注意: 必须在 reset 前调用一次 (采样当月最终值), reset 会清零计数。
get_monthly_tx() {
    local month_tx
    month_tx=\$("/root/netstat.sh" 2>/dev/null)
    if [ -z "\$month_tx" ] || ! [[ "\$month_tx" =~ ^[0-9]+$ ]]; then
        month_tx=0
    fi
    echo "\$month_tx"
}

# 流量格式化: 按 MB -> GB -> TB 层级递进
format_traffic() {
    local bytes b
    bytes="\$1"
    case "\$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    b=\$(echo "scale=2; \$bytes / 1073741824" | bc)
    if [ \$(echo "\$b < 1" | bc) -eq 1 ]; then
        echo "\$(echo "scale=2; \$bytes / 1048576" | bc)MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        echo "\${b}GB"
    else
        echo "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)TB"
    fi
}

# oracle 平台判定：平台名包含 oracle/甲骨文（大小写不敏感）
is_oracle_platform() {
    echo "\$PLATFORM" | grep -qiE 'oracle|甲骨文'
}

# 判定 CPU 类型 (AMD / ARM)
get_cpu_type() {
    local arch ctype
    arch=\$(uname -m)
    ctype=\$(lscpu 2>/dev/null | awk -F: '/^Vendor ID|^型号名称|^Model name/ {print \$2}' | head -n1)
    if [[ "\$arch" == aarch64 || "\$arch" == arm* ]]; then
        echo "ARM"
    elif echo "\$arch \$ctype" | grep -qi "amd\|epyc"; then
        echo "AMD"
    else
        echo "AMD"
    fi
}

log "开始执行每月网络重置..."

# 0. 读取当月状态
CUR_MONTH=\$(date '+%Y-%m')
[ -f "\$STATE_FILE" ] && . "\$STATE_FILE"
[ -z "\$STATE" ] && STATE=normal
[ -z "\$MONTH" ] && MONTH="\$CUR_MONTH"

# 1. 删除旧的流量监控日志
if [ -f "\$TRAFFIC_LOG" ]; then
    rm -f "\$TRAFFIC_LOG"
    log "已删除旧的流量监控日志: \$TRAFFIC_LOG"
else
    log "流量监控日志不存在，无需删除。"
fi

# 2. 重置防火墙规则 (IPv4 + IPv6)
# 只移除本脚本的出站封禁规则 (TRAFFIC_BLOCKED 链及 OUTPUT 跳转规则)，不影响其他程序
unblock_fw() {
    local FW="\$1"
    command -v "\$FW" >/dev/null 2>&1 || return 0
    # 仅清理本脚本的跳转 (兼容新旧注释；只删带自身注释的跳转，不动其他程序规则)
    "\$FW" -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本仅断出站(SSH/DNS/lo 除外)" -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本仅断出站(SSH/DNS/lo 除外)" -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本仅断出站(SSH/DNS/lo 除外)" -j TRAFFIC_BLOCKED 2>/dev/null
    # 兼容旧版本(无注释的裸跳转也一并删除，仅限本脚本曾用)
    "\$FW" -D INPUT    -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D OUTPUT   -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -D FORWARD  -j TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -F TRAFFIC_BLOCKED 2>/dev/null
    "\$FW" -X TRAFFIC_BLOCKED 2>/dev/null
}
[ "\$HAS_V4" = "1" ] && unblock_fw iptables
[ "\$HAS_V6" = "1" ] && unblock_fw ip6tables
log "已移除本脚本的封网规则 (TRAFFIC_BLOCKED)，网络恢复。"

# 3. 重置流量统计 (nezha 式 netstat.sh 清零当月累计)
#    在重置前先采样"上个月"最终出站流量 (reset 后计数清零，用于恢复通知展示)
LAST_MONTH_TX=\$(get_monthly_tx)
if [ -n "\$LAST_MONTH_TX" ] && [ "\$LAST_MONTH_TX" -gt 0 ] 2>/dev/null; then
    log "上个月出站流量: \$(format_traffic "\$LAST_MONTH_TX") (\$LAST_MONTH_TX Bytes)"
fi
/root/netstat.sh --reset >/dev/null 2>&1 || true
log "流量统计已重置 (netstat.sh 当月累计清零)。"

# 4. 网络恢复后发送 TG 通知 (仅当 TG 启用且上月处于断网状态时发送一次)
#    在防火墙已全部放开之后发送 (此时网络可用，能获取 IP)
sleep 1

# 判定是否需要发恢复通知: 仅当 STATE=blocked (即上个周期确实超限封网过) 才需要
NEED_RESTORE=0
if [ "\$STATE" = "blocked" ] && [ "\$TG_ON" = "1" ]; then
    NEED_RESTORE=1
fi

# 更新状态文件: 恢复 -> normal，记录恢复时间，进入新月份周期
STATE=normal
MONTH="\$CUR_MONTH"
RESTORED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "\$(dirname "\$STATE_FILE")"
cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME="\$BLOCKED_TIME"
BLOCKED_TX="\$BLOCKED_TX"
RESTORED_TIME="\$RESTORED_TIME"
STATE_EOF

if [ "\$NEED_RESTORE" -eq 1 ]; then
IFS='|' read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
    RUN_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
    MONTH_TX=\$(get_monthly_tx)
    # 上个月(重置前周期)最终流量: 优先用步骤3采样值, 若为0则回退到 max(当前,采样)
    LAST_MONTH_OK=0
    if [ -n "\$LAST_MONTH_TX" ] && [ "\$LAST_MONTH_TX" -gt 0 ] 2>/dev/null; then
        LAST_MONTH_OK=1
    elif [ "\$MONTH_TX" -gt 0 ] 2>/dev/null; then
        LAST_MONTH_TX="\$MONTH_TX"
        LAST_MONTH_OK=1
    fi
    # CPU 行 (仅 oracle 显示)
    CPU_LINE=""
    if is_oracle_platform; then
        CPU_LINE="
🌐 CPU: \$(get_cpu_type)"
    fi

    # 本月流量/上限 恒显示; 有上月(重置前)记录时附加展示
    LAST_MONTH_LINE=""
    if [ "\$LAST_MONTH_OK" = "1" ]; then
        LAST_MONTH_LINE="
📊 上个月流量: \$(format_traffic "\$LAST_MONTH_TX") (重置前出站耗尽)"
    fi

    TG_MSG="🎮 \$PLATFORM 流量报告（网络恢复通知）

🌐 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$RUN_TIME
📚 网络状态: 超限封网 ---> 已恢复
🌐 本月流量: \$(format_traffic "\$MONTH_TX") / 上限: \$LIMIT GB\${LAST_MONTH_LINE}\${CPU_LINE}"

    tg_send "\$TG_MSG"
    log "已发送网络恢复 TG 通知。"
else
    log "上月网络正常（或 TG 未启用），无需发送恢复通知。"
fi
EOF

# 6. 赋予执行权限
chmod +x /root/check_traffic.sh
chmod +x /root/reset_network.sh

# 7. 设置定时任务
echo "--> 更新 Crontab 定时任务..."
crontab -l > /tmp/cron_bk 2>/dev/null

# 清理旧任务，防止重复
sed -i '/check_traffic.sh/d' /tmp/cron_bk
sed -i '/reset_network.sh/d' /tmp/cron_bk

# 添加新任务
# 每5分钟检查一次流量
echo "*/5 * * * * /root/check_traffic.sh" >> /tmp/cron_bk
# 每月1号 00:00 重置网络和日志
echo "0 0 1 * * /root/reset_network.sh" >> /tmp/cron_bk

crontab /tmp/cron_bk
rm /tmp/cron_bk

# 确保 cron 服务运行 (Debian/Ubuntu 一般默认开启；Alpine busybox crond 需显式启动)
if [ "$SVC_MGR" = "openrc" ]; then
    rc-update add crond default 2>/dev/null
    rc-service crond start 2>/dev/null
fi

echo "=========================================="
echo " 安装完成！($PLATFORM)"
echo "=========================================="
echo "您可以手动运行以下命令查看精确流量："
echo "  bash /root/check_traffic.sh"
echo ""
echo "运行时配置文件   : $CONF_FILE (0600，请勿手改；改动请用子命令)"
echo "TG 密钥文件      : $NETMON_KEY (0600，丢失后凭据不可恢复)"
echo ""
echo "后续配置修改/查看命令："
echo "  bash $0 edit       # 交互式菜单：修改平台/上限/端口/DNS/网卡/TG"
echo "  bash $0 config     # 查看当前配置 (TG 凭据掩码显示)"
echo "  bash $0 set-tg     # 换 TG: TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash $0 set-tg"
echo "  bash $0 clear-tg   # 停用并清除 TG 凭据"
echo "  bash /root/check_traffic.sh   # 手动查看流量"
echo "=========================================="
echo "当前配置："
echo "  平台       : $PLATFORM"
echo "  流量上限   : $LIMIT GB"
echo "  SSH 端口   : $SSH_PORT"
echo "  封网策略   : 超限时双向封锁 (INPUT+OUTPUT+FORWARD DROP)"
echo "             仅放行 SSH(入/出双向)/DNS/lo；转发至其他 VPS 的流量一并拦截"
if [ "$TG_ENABLED" = "1" ]; then
    echo "  TG 通知    : 已启用 (凭据已加密存储，断网/恢复时通知)"
else
    echo "  TG 通知    : 未启用 (未传 TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)"
    echo "              启用: TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash $0"
fi
echo "=========================================="