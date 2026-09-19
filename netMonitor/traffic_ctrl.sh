#!/bin/bash

# ==========================================
# 流量监控自动部署脚本 (通用任意平台 / 可选 Telegram 通知)
# 功能：
# 1. 自动获取网卡，分别统计上下行流量 (RX 入站 / TX 出站)，超限口径可配置
# 2. 运行 check_traffic.sh 时终端显示精确流量，日志保留简略信息
# 3. 每月重置流量，并清理旧日志（只保留最近 N 天，默认 7 天，可配 LOG_RETENTION_DAYS）
# 4. 超限后双向封锁 (INPUT + OUTPUT + FORWARD DROP)，仅保留 SSH(入/出双向永放行)/DNS/lo
# 5. oracle 平台自动停用 firewalld / ufw，避免与 iptables 冲突
# 6. TG 通知（可选）：断网前发一条、每月1号恢复发一条
#
# 【流量口径 STAT_MODE】写入 ${CONF_DIR}/netMonitor.conf（默认 /etc/traffic_routing/netMonitor.conf），可用 edit 子命令修改：
#   out  -> 只算出站(上行)   in -> 只算入站(下行)
#   max -> 取上下行中较大者  sum -> 上下行之和(总流量)
#
# 【配置方式】
# 部署时的全部配置写入 CONF_DIR 下的 netMonitor.conf（默认 /etc/traffic_routing/netMonitor.conf）。
# TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 不明文保存：部署时用 AES-256 加密
# （密钥在 CONF_DIR 下的 netMonitor.key，权限 0600）后以 *_ENC 字段写入。
# 运行时脚本用密钥文件解密后使用，密码不落盘、不出现在命令行参数。
#
# 之后修改配置【统一通过子命令，勿直接手改文件】：
#   bash traffic_ctrl.sh            # 不加参数 = 进入管理菜单（部署/查看/修改/卸载/退出）
#   bash traffic_ctrl.sh req        # 部署 / 重新部署（覆盖式，先卸后装；LIMIT 必须显式指定）
#   bash traffic_ctrl.sh edit       # 交互式菜单：改平台/上限/端口/DNS/网卡/TG/日志保留
#   bash traffic_ctrl.sh set-tg     # 更换 TG（从环境变量 TELEGRAM_BOT_TOKEN/CHAT_ID 读取）
#   bash traffic_ctrl.sh clear-tg   # 停用并清除 TG 凭据
#   bash traffic_ctrl.sh config     # 查看当前配置（TG 凭据以掩码显示）
#   bash traffic_ctrl.sh del        # 卸载（保留密钥与月度档案；netcount 当月玉芬保留，覆盖式重装后继续累计）
#   bash traffic_ctrl.sh help       # 查看全部命令用法
#
# 平台差异通过 PLATFORM 区分（建议统一小写）：
# 自动停用 firewalld/ufw
# 其他任意标识可用（aws/azure/hetzner/custom...），仅需手动指定 LIMIT：
#     例: PLATFORM=aws LIMIT=1024 bash traffic_ctrl.sh
# ==========================================

# ==========================================
# 部署参数（全部可用环境变量覆盖，未设置时取默认值）
# ==========================================
# 平台标识: 建议全部用小写。
#   内置特殊处理: gcp / oracle
#     - gcp    -> LIMIT 
#     - oracle -> LIMIT 并自动停用 firewalld/ufw
#   其他任意平台标识也可用（如 aws / azure / hetzner / custom...），
#   仅需手动指定 LIMIT；TG 通知标题会显示对应的平台名。
PLATFORM="${PLATFORM:-gcp}"

# --- 作者 / 版本（部署期常量，落盘 conf，菜单统一读取展示）---
# AUTHOR: 脚本作者署名；VERSION: 与仓库根 VERSION 文件保持一致，升级时同步手改
AUTHOR="${AUTHOR:-littleDoraemon}"
VERSION="${VERSION:-v1.0.15}"

# 出站流量上限 (GB)，超过该值触发封网
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

# 运行时脚本目录：生成的 check/reset/netstat 三个脚本统一收拢于此，
# 部署流程会提前 mkdir -p 创建（覆盖式重装/升级时复用同一目录）
SCRIPT_DIR="${SCRIPT_DIR:-/root/traffic_routing}"
# 运行时配置目录：conf/key 统一收拢于此，方便以后整体迁移；
# 部署流程会提前 mkdir -p 创建，uninstall 会清理此目录下的本脚本文件
CONF_DIR="${CONF_DIR:-/etc/traffic_routing}"
# 快捷指令名：部署后在 /usr/local/bin 下创建同名 symlink，指向部署器实际路径；
# 之后可用 tfc 代替 bash /path/to/traffic_ctrl.sh（如 tfc config / tfc check）
TFC_NAME="${TFC_NAME:-tfc}"
# 运行时配置文件路径（一般通过 CONF_DIR 派生；需共享配置时可单独重定向 CONF_FILE）
CONF_FILE="${CONF_FILE:-$CONF_DIR/netMonitor.conf}"
# TG 凭据加密密钥文件（0600，root-only；丢失后凭据不可恢复，需重新 set-tg）
NETMON_KEY="${NETMON_KEY:-$CONF_DIR/netMonitor.key}"
# 流量监控日志保留天数：每月 1 号 reset_network.sh 清理时，只保留最近 N 天的日志行，
# 删除 N 天以前的旧日志（默认 7 天）；0/-1 = 保留全部不清理。
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
case "$LOG_RETENTION_DAYS" in
    ''|*[!0-9-]*|-) LOG_RETENTION_DAYS=7 ;;
esac
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

# LIMIT 无任何默认值：部署时必须显式给出（环境变量 LIMIT 或 edit 菜单项 2 修改）。
# 语义：0/-1 = 无限制（永不触发封网）；>0 = 上限 GB。未设置时部署流程直接报错退出。

# 流量统计口径（超限判断用哪个方向的流量）：
#   out  -> 只算出站(上行)   in  -> 只算入站(下行)
#   max -> 取上下行中较大者  sum -> 上下行之和 (总流量)
# 平台默认（首次部署时写入 conf，可用 edit 子命令改）：
#   gcp/out 出站、oracle/in 入站、其他平台 sum 总和 —— 与平台计费口径一一对应。
# 流量统计口径（超限判断用哪个方向的流量）：
#   in  -> 只算入站(下行)   out -> 只算出站(上行)
#   max -> 取上下行较大者    min -> 取上下行较小者   sum -> 上下行总和 (总流量)
# 首次部署未显式设置时统一取 sum（总和）——不再按平台自动分派；
# 要改成 in/out/max/min 请用 edit 子命令（会同步写入 conf 供运行时读取）。
STAT_MODE="${STAT_MODE:-sum}"
case "$STAT_MODE" in in|out|max|min|sum) : ;; *) STAT_MODE=sum ;; esac

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
        return 1
    fi
}

# ---------------- 内部函数：quick_install ----------------
# 落盘部署器到 SCRIPT_DIR/traffic_ctrl.sh + 建 /usr/local/bin/tfc 链接；幂等可重入。
# 失败时 return 1（由调用方降级为警告，绝不 exit 中断部署本身）；
# $0 为 curl 进程替换时 fd 可能已被读空，此时提示手动 wget 落盘。
quick_install() {
    require_root
    mkdir -p "$SCRIPT_DIR"
    DEPLOYER_DST="$SCRIPT_DIR/traffic_ctrl.sh"
    case "$0" in
        /dev/fd/*|/proc/self/fd/*)
            # 进程替换的 fd 在部署过程中已被读空，此处不再尝试落盘（避免产生空文件坏链接）；
            # 用户手动 wget 落盘后，tfc 即等价于 bash 落盘路径
            echo "--> 提示：本次为 curl 进程替换安装，未自动创建快捷指令。" >&2
            echo "    请手动执行：wget -O $DEPLOYER_DST https://raw.githubusercontent.com/jyucoeng/gcp_traffic_routing/main/netMonitor/traffic_ctrl.sh && chmod +x $DEPLOYER_DST && ln -sf $DEPLOYER_DST /usr/local/bin/${TFC_NAME:-tfc}" >&2
            return 1
            ;;
        *)
            if [ -f "$0" ]; then
                if [ "$0" != "$DEPLOYER_DST" ]; then
                    cp -f "$0" "$DEPLOYER_DST" 2>/dev/null || cat "$0" > "$DEPLOYER_DST" 2>/dev/null || true
                fi
            else
                echo "--> 提示：找不到部署器文件（$0），跳过快捷指令创建。" >&2
                return 1
            fi
            ;;
    esac
    # 落盘文件非空校验：空文件不建链接（防坏链接误导）
    [ -s "$DEPLOYER_DST" ] || { echo "--> 提示：落盘文件为空，跳过快捷指令创建。" >&2; return 1; }
    chmod +x "$DEPLOYER_DST"
    mkdir -p /usr/local/bin 2>/dev/null || true
    ln -sf "$DEPLOYER_DST" "/usr/local/bin/${TFC_NAME:-tfc}"
    echo "--> 快捷指令已创建：${TFC_NAME:-tfc} -> $DEPLOYER_DST"
    echo "    用法：${TFC_NAME:-tfc} config|check|restore|edit|menu"
}

# ==================================================
# 卸载函数（del 子命令 / 覆盖式安装共用）
# 只清理"本脚本自己的部署物"，不动宿主其他 crontab/iptables 规则；
# 覆盖式安装 = 部署流程先调用本函数清掉旧物，再重新完整部署。
# 本函数仅属外层部署器；两份 heredoc 生成的 check/reset 是独立运行时脚本，无需各自的 uninstall。
# 保留项：NETMON_KEY（TG 凭据 AES 密钥，覆盖式重装复用，免重配 TG）与月度档案 archive（历史流量长期留存）。
# ==================================================
uninstall() {
    echo "--> 正在卸载..."
    # 1. 从 crontab 移除本脚本的两条调度（只删含 check_traffic/reset_network 的行，保留其他任务）
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vE 'check_traffic\.sh|reset_network\.sh' | crontab - 2>/dev/null || true
        echo "  -> 定时任务已清理。"
    fi

    # 2. 删除部署时生成的运行时脚本（SCRIPT_DIR；兼容清理旧版 /root 直放路径）与快捷指令
    rm -f "$SCRIPT_DIR/check_traffic.sh" "$SCRIPT_DIR/reset_network.sh" "$SCRIPT_DIR/netstat.sh" 2>/dev/null || true
    rm -f /root/check_traffic.sh /root/reset_network.sh /root/netstat.sh 2>/dev/null || true
    if [ -e "/usr/local/bin/${TFC_NAME:-tfc}" ]; then
        rm -f "/usr/local/bin/${TFC_NAME:-tfc}" 2>/dev/null || true
        echo "  -> 快捷指令 ${TFC_NAME:-tfc} 已删除。"
    fi
    rmdir "$SCRIPT_DIR" 2>/dev/null || true
    echo "  -> 运行时脚本已清理。"

    # 3. 删除运行时配置（保留 NETMON_KEY：覆盖式重装复用 TG 密钥；兼容删旧版硬编码路径）
    [ -n "${CONF_FILE:-}" ] && rm -f "$CONF_FILE"
    rm -f /etc/netMonitor.conf 2>/dev/null || true
    [ -n "${CONF_DIR:-}" ] && rmdir "$CONF_DIR" 2>/dev/null || true
    echo "  -> 运行时配置已清理（密钥保留）。"

    # 4. 清理本脚本的封网规则（只删自家 TRAFFIC_BLOCKED 链及跳转，不动其他程序规则/默认策略）
    for _FW in iptables ip6tables; do
        command -v "$_FW" >/dev/null 2>&1 || continue
        for _CHAIN in INPUT OUTPUT FORWARD; do
            "$_FW" -D "$_CHAIN" -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null || true
            "$_FW" -D "$_CHAIN" -m comment --comment "TRAFFIC_BLOCKED: 脚本仅断出站(SSH/DNS/lo 除外)" -j TRAFFIC_BLOCKED 2>/dev/null || true
            "$_FW" -D "$_CHAIN" -j TRAFFIC_BLOCKED 2>/dev/null || true
        done
        "$_FW" -F TRAFFIC_BLOCKED 2>/dev/null || true
        "$_FW" -X TRAFFIC_BLOCKED 2>/dev/null || true
    done
    echo "  -> 封网规则已清理，网络已恢复。"

    # 5. 删除运行时状态/计数/日志（保留 archive 月度档案：长期留存上月流量结存）
    # 卸载清除本月状态(state)与 TG 发送历史(notify)；本月流量计数(netcount)保留 --
    # 覆盖式重装后继续累计当月实时流量；notify 清空后同月重装会重新发送通知（视为全新部署）
    rm -f /var/lib/traffic_monitor/state /var/lib/traffic_monitor/notify 2>/dev/null || true
    rm -f /var/log/traffic_monitor.log /var/log/network_reset.log 2>/dev/null || true
    rm -f /var/log/netMonitor_check.log /var/log/netMonitor_reset.log 2>/dev/null || true
    echo "  -> 状态与日志已清理（月度档案保留）。"

    echo "  -> 已卸载（旧部署物已清理，密钥与月度档案保留；如需重新部署请直接 bash $0 执行覆盖式安装）。"
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
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# netMonitor 运行时配置
# 修改配置请用：bash traffic_ctrl.sh edit（交互式菜单）；请勿手改本文件
# TELEGRAM_*_ENC 为 AES-256 加密密文（密钥 ${NETMON_KEY}，权限 0600），请勿手改；
# 更换 TG 凭据也可用：bash traffic_ctrl.sh set-tg
PLATFORM="$PLATFORM"
LIMIT=$LIMIT
STAT_MODE=$STAT_MODE
SSH_PORT=$SSH_PORT
DNS_SERVERS="$DNS_SERVERS"
HAS_V4=$HAS_V4
HAS_V6=$HAS_V6
# 作者 / 版本（部署期常量，供菜单展示；也随 conf 落盘供运行时/生成脚本读取）
AUTHOR="$AUTHOR"
VERSION="$VERSION"
TELEGRAM_BOT_TOKEN_ENC="$(enc_tg "$TELEGRAM_BOT_TOKEN")"
TELEGRAM_CHAT_ID_ENC="$(enc_tg "$TELEGRAM_CHAT_ID")"
INTERFACE="$INTERFACE"
# 流量监控日志保留天数：每月 1 号清理时只保留最近 N 天的日志（0/-1=保留全部）
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
EOF
    chmod 0600 "$CONF_FILE"
}

# ---------------- 子命令：set-tg / clear-tg ----------------
# 仅更新 TG 凭据（加密落盘），不影响其余配置，不重装依赖/不动 crontab。
tg_set() {
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署（bash traffic_ctrl.sh）再设置 TG。" >&2
        return 1
    fi
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "用法：TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash $0 set-tg" >&2
        return 1
    fi
    # 读取现有配置以保留其余字段
    . "$CONF_FILE"
    INTERFACE="${INTERFACE:-}"
    STAT_MODE="${STAT_MODE:-sum}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
    gen_key
    write_conf
    echo "TG 凭据已更新（加密写入 ${CONF_FILE}）。"
}

tg_clear() {
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署。" >&2
        return 1
    fi
    . "$CONF_FILE"
    INTERFACE="${INTERFACE:-}"
    STAT_MODE="${STAT_MODE:-sum}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    gen_key
    write_conf
    echo "TG 凭据已清除（关闭通知）。"
}

# ---------------- 子命令：reset-notify ----------------
# 重置本月 TG 发送计数：删掉 notify 历史中本月的行（OVER/RESTORE 重置为可发送）；
# 历史月份保留；删整个文件=清空全部历史。本月超限/恢复通知可重新各发 1 条。
tg_notify_reset() {
    require_root
    _nf="${NOTIFY_FILE:-/var/lib/traffic_monitor/notify}"
    _m="$(date '+%Y-%m')"
    if [ ! -f "$_nf" ]; then
        echo "本月（$_m）无 TG 发送记录，无需重置。"
        return 0
    fi
    _before="$(grep -cE "^${_m}[[:space:]]|^OVER_MONTH=${_m}$|^RESTORE_MONTH=${_m}$" "$_nf" 2>/dev/null)"
    _tmp="${_nf}.tmp"
    grep -Ev "^${_m}[[:space:]]" "$_nf" 2>/dev/null | grep -Ev "^OVER_MONTH=${_m}$" | grep -Ev "^RESTORE_MONTH=${_m}$" > "$_tmp" 2>/dev/null || : > "$_tmp"
    cat "$_tmp" > "$_nf"
    rm -f "$_tmp"
    if [ "${_before:-0}" -gt 0 ] 2>/dev/null; then
        echo "已重置本月（$_m）TG 发送计数，超限/恢复通知可重新各发 1 条。"
    else
        echo "本月（$_m）无 TG 发送记录，无需重置。"
    fi
}

# 共用菜单头：一级/二级/config 统一（标题+作者+版本+网络状态+TG通知+快捷指令）
# TG 行：conf 缺失=未部署(黄)；凭据齐=已启用(绿)；否则未启用(红)
menu_tg_status() {
    _cf="${CONF_FILE:-/etc/traffic_routing/netMonitor.conf}"
    [ -f "$_cf" ] || { printf '\033[33m未部署\033[0m'; return 0; }
    # shellcheck disable=SC1090
    . "$_cf" 2>/dev/null || { printf '\033[31m未启用\033[0m'; return 0; }
    if [ -n "${TELEGRAM_BOT_TOKEN_ENC:-}" ] && [ -n "${TELEGRAM_CHAT_ID_ENC:-}" ]; then
        printf '\033[32m已启用\033[0m'
    else
        printf '\033[31m未启用\033[0m'
    fi
}
menu_header() {
    echo "========================="
    echo " 小鸡流量限制管理脚本"
    echo " Author：${AUTHOR}"
    echo " Version: ${VERSION}"
    echo " 网络状态：$(menu_net_status)"
    echo " TG 通知：$(menu_tg_status)"
    echo " 快捷指令：${TFC_NAME:-tfc}"
    echo "========================="
}

# ---------------- 子命令：config ----------------
# 查看当前运行时配置；TG 凭据解密后以掩码显示（保留前4后4，隐藏中间）。
config_show() {
    require_root
    if [ ! -r "$CONF_FILE" ]; then
        echo "错误：未找到 ${CONF_FILE}，请先部署（bash traffic_ctrl.sh）。" >&2
        return 1
    fi
    . "$CONF_FILE"
    TELEGRAM_BOT_TOKEN_ENC="${TELEGRAM_BOT_TOKEN_ENC:-}"
    TELEGRAM_CHAT_ID_ENC="${TELEGRAM_CHAT_ID_ENC:-}"
    INTERFACE="${INTERFACE:-}"

    local t c
    t="$(dec_tg "$TELEGRAM_BOT_TOKEN_ENC")"
    c="$(dec_tg "$TELEGRAM_CHAT_ID_ENC")"

    menu_header
    echo "平台         : ${PLATFORM:-gcp}"
    echo "流量上限     : ${LIMIT:-未设置} GB"
    echo "流量口径     : ${STAT_MODE:-sum} (out=出站 in=入站 max=取大 min=取小 sum=总和)"
    echo "SSH 端口     : ${SSH_PORT:-22}"
    echo "DNS 服务器   : ${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
    echo "网卡接口     : ${INTERFACE:-}"
    echo "日志保留     : ${LOG_RETENTION_DAYS:-7} 天 (只保留最近 N 天, 0/-1=保留全部)"
    if [ -n "$t" ] && [ -n "$c" ]; then
        echo -e "TG 通知      : \033[32m已启用\033[0m"
        echo "  BOT TOKEN  : $(mask_mid "$t")  (长度 ${#t})"
        echo "  CHAT ID    : $(mask_mid "$c")  (长度 ${#c})"
    else
        echo -e "TG 通知      : \033[31m未启用\033[0m"
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
        return 1
    fi
    . "$CONF_FILE"
    TELEGRAM_BOT_TOKEN_ENC="${TELEGRAM_BOT_TOKEN_ENC:-}"
    TELEGRAM_CHAT_ID_ENC="${TELEGRAM_CHAT_ID_ENC:-}"
    INTERFACE="${INTERFACE:-}"
    STAT_MODE="${STAT_MODE:-sum}"
    HAS_V4="${HAS_V4:-1}"
    HAS_V6="${HAS_V6:-1}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
    case "$STAT_MODE" in out|in|max|min|sum) : ;; *) STAT_MODE=sum ;; esac
    case "$LOG_RETENTION_DAYS" in
        ''|*[!0-9-]*|-) LOG_RETENTION_DAYS=7 ;;
    esac

    # 解密现有 TG 以便编辑后原样回写（不输入即保留）
    local t c
    t="$(dec_tg "$TELEGRAM_BOT_TOKEN_ENC")"
    c="$(dec_tg "$TELEGRAM_CHAT_ID_ENC")"

    # 单项即改即保存：每改一项直接加密落盘，无需最后统一保存
    save_edit() {
        TELEGRAM_BOT_TOKEN="$t"
        TELEGRAM_CHAT_ID="$c"
        gen_key
        write_conf
        echo "-> 已保存（加密写入 ${CONF_FILE}），即时生效。"
    }

    while :; do
        echo ""
        menu_header
        echo "  平台 PLATFORM    : ${PLATFORM:-gcp}"
        echo "  流量上限 LIMIT   : ${LIMIT:-未设置} GB (0/-1=无限制)"
        echo "  流量口径 STAT_MODE: ${STAT_MODE:-sum} (out=出站 in=入站 max=取大 min=取小 sum=总和)"
        echo "  SSH 端口         : ${SSH_PORT:-22}"
        echo "  DNS 服务器       : ${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
        echo "  网卡接口         : ${INTERFACE:-}"
        echo "  日志保留天数     : ${LOG_RETENTION_DAYS:-7} (只保留最近 N 天, 0/-1=保留全部)"
        if [ -n "$t" ] && [ -n "$c" ]; then _tg_st="$(printf '\033[32m已启用\033[0m')"; else _tg_st="$(printf '\033[31m未启用\033[0m')"; fi
        echo "  TG 通知          : $_tg_st"
        echo "========================================"
        echo " 1) 修改平台         2) 修改流量上限(0/-1=无限制)"
        echo " 3) 修改流量口径     4) 修改 SSH 端口"
        echo " 5) 修改 DNS 服务器  6) 修改 TG 凭据"
        echo " 7) 清空 TG 凭据     8) 修改日志保留天数"
        echo " 9) 重置 DNS 为自动"
        echo " 0) 返回上级菜单"
        echo "========================================"
        printf "请选择: "
        read -r opt || break

        case "$opt" in
            1)
                printf "新平台(建议小写，如 gcp/oracle/aws/custom) [${PLATFORM:-gcp}]: "; read -r v
                if [ -n "$v" ]; then PLATFORM="$v"; save_edit; fi
                ;;
            2)
                printf "新上限 GB (0/-1=无限制，留空=不设置) [${LIMIT:-未设置}]: "; read -r v
                case "$v" in
                    "") LIMIT="" ; save_edit ;;
                    -1) LIMIT="-1" ; save_edit ;;
                    0)  LIMIT="0" ; save_edit ;;
                    *[!0-9.]*) echo "无效上限（仅允许非负数，0/-1=无限制，留空=不设置）。" ;;
                    *) LIMIT="$v" ; save_edit ;;
                esac
                ;;
            3)
                printf "流量口径: out(出站) in(入站) max(取大) min(取小) sum(总和) [${STAT_MODE:-sum}]: "; read -r v
                case "$v" in
                    out|in|max|min|sum) STAT_MODE="$v" ; save_edit ;;
                    "") : ;;
                    *) echo "无效口径，保留 ${STAT_MODE:-sum}。" ;;
                esac
                ;;
            4)
                printf "新 SSH 端口 [${SSH_PORT:-22}]: "; read -r v
                if [ -n "$v" ]; then SSH_PORT="$v"; save_edit; fi
                ;;
            5)
                printf "新 DNS 服务器(空格分隔) [${DNS_SERVERS:-8.8.8.8 8.8.4.4}]: "; read -r v
                if [ -n "$v" ]; then
                    _dns_ok=1
                    for _d in $v; do
                        case "$_d" in
                            *.*|*:*) : ;;
                            *) _dns_ok=0; break ;;
                        esac
                    done
                    if [ "$_dns_ok" = "1" ]; then DNS_SERVERS="$v"; save_edit; else echo "无效 DNS（每项须含 . 或 :，如 8.8.8.8），未保存。"; fi
                fi
                ;;
            6)
                printf "新 Bot Token (留空保持不变): "; read -r t2
                echo -e "  │→ Bot Token: \033[32m${t2:-保持不变}\033[0m"
                printf "新 Chat ID (留空保持不变): "; read -r c2
                echo -e "  │→ Chat ID: \033[32m${c2:-保持不变}\033[0m"
                [ -n "$t2" ] && t="$t2"
                [ -n "$c2" ] && c="$c2"
                save_edit
                ;;
            7)
                t=""
                c=""
                save_edit
                echo "-> TG 凭据已清空"
                ;;
            8)
                printf "日志保留天数 (0/-1=保留全部) [${LOG_RETENTION_DAYS:-7}]: "; read -r v
                case "$v" in
                    "") : ;;
                    -1) LOG_RETENTION_DAYS="-1" ; save_edit ;;
                    0)  LOG_RETENTION_DAYS="0" ; save_edit ;;
                    *[!0-9]*) echo "无效天数（仅允许非负整数，0/-1=保留全部）。" ;;
                    *) LOG_RETENTION_DAYS="$v" ; save_edit ;;
                esac
                ;;
            9)
                # 重置 DNS 为自动：清空后按地址族重算（HAS_V4/HAS_V6 部署期探测值；
                # 双栈/纯v4 用 8.8.8.8，纯v6 用 Google IPv6 DNS），即时生效
                DNS_SERVERS=""
                if [ "${HAS_V4:-1}" = "0" ] && [ "${HAS_V6:-1}" = "1" ]; then
                    DNS_SERVERS="2001:4860:4860::8888 2001:4860:4860::8844"
                else
                    DNS_SERVERS="8.8.8.8 8.8.4.4"
                fi
                save_edit
                echo -e "  │→ DNS 已重置为自动: \033[32m$DNS_SERVERS\033[0m"
                ;;
            0)
                echo "-> 返回上级菜单。"
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# ---------------- 子命令：menu / 默认入口 ----------------
# 不加参数或 menu 子命令进入管理菜单（部署/查看/修改/卸载/退出）
# 菜单安装参数 pergunta：$1=1 全新 / 2 覆盖；逐项列出让用户确认（回车保留默认）；
# 全新用硬默认，覆盖读现 conf 做默认；LIMIT 必填（两处都无默认时必须输入）；
# 返回 0=继续安装，1=取消。无交互 req 不走这里（环境变量直装）。
menu_install_ask() {
    _mode="$1"
    _cf="${CONF_FILE:-/etc/traffic_routing/netMonitor.conf}"
    if [ "$_mode" = "2" ] && [ -f "$_cf" ]; then
        . "$_cf"
        _d_platform="${PLATFORM:-gcp}"
        _d_limit="${LIMIT:-}"
        _d_stat="${STAT_MODE:-sum}"
        _d_ssh="${SSH_PORT:-22}"
        _d_dns="${DNS_SERVERS:-}"
        _d_log="${LOG_RETENTION_DAYS:-7}"
        _has_tg=0
        [ -n "${TELEGRAM_BOT_TOKEN_ENC:-}" ] && [ -n "${TELEGRAM_CHAT_ID_ENC:-}" ] && _has_tg=1
    else
        _d_platform="${PLATFORM:-gcp}"
        _d_limit="${LIMIT:-}"
        _d_stat="${STAT_MODE:-sum}"
        _d_ssh="${SSH_PORT:-22}"
        _d_dns="${DNS_SERVERS:-}"
        _d_log="${LOG_RETENTION_DAYS:-7}"
        _has_tg=0
    fi
    echo ""
    if [ "$_mode" = "1" ]; then
        echo "--- 全新安装参数（回车用默认值）---"
    else
        echo "--- 覆盖安装参数（回车保留现值）---"
    fi
    printf "平台 PLATFORM [%s]: " "$_d_platform"; read -r v || return 1
    [ -n "$v" ] && PLATFORM="$v" || PLATFORM="$_d_platform"
    echo -e "  │→ 平台: \033[32m$PLATFORM\033[0m"
    echo "流量口径 STAT_MODE 可选项："
    echo "  in=入站  out=出站  max=取大  min=取小  sum=总和"
    while :; do
        printf "流量口径 [默认 %s]: " "$_d_stat"; read -r v || return 1
        case "$v" in
            "") STAT_MODE="$_d_stat"; break ;;
            in|out|max|min|sum) STAT_MODE="$v"; break ;;
            *) echo "无效口径，请从 in/out/max/min/sum 中选择。" ;;
        esac
    done
    echo -e "  │→ 流量口径: \033[32m$STAT_MODE\033[0m"
    while :; do
        if [ -n "$_d_limit" ]; then
            printf "流量上限 LIMIT(GB) [%s]: " "$_d_limit"; read -r v || return 1
            [ -z "$v" ] && v="$_d_limit"
        else
            printf "流量上限 LIMIT(GB, 必填): "; read -r v || return 1
        fi
        case "$v" in
            "") echo "LIMIT 为必填项，请输入。" ; continue ;;
            -1|0) LIMIT="$v"; break ;;
            *[!0-9.]*|.*.*.*) echo "无效上限（仅允许非负数，0/-1=无限制），请重新输入。" ; continue ;;
            .*) echo "无效上限（仅允许非负数，0/-1=无限制），请重新输入。" ; continue ;;
            *) LIMIT="$v"; break ;;
        esac
    done
    echo -e "  │→ 流量上限: \033[32m${LIMIT}GB\033[0m"
    printf "SSH 端口 [默认 %s，一般不用改]: " "$_d_ssh"; read -r v || return 1
    [ -n "$v" ] && SSH_PORT="$v" || SSH_PORT="$_d_ssh"
    echo -e "  │→ SSH 端口: \033[32m$SSH_PORT\033[0m"
    printf "DNS 服务器(空格分隔, 留空自动) [%s]: " "${_d_dns:-自动}"; read -r v || return 1
    [ -n "$v" ] && DNS_SERVERS="$v" || DNS_SERVERS="$_d_dns"
    echo -e "  │→ DNS 服务器: \033[32m${DNS_SERVERS:-自动}\033[0m"
    if [ "$_has_tg" = "1" ]; then
        printf "TG 凭据 [已启用，回车保留，输入 clear 清除]: "; read -r v || return 1
        case "$v" in
            clear|CLEAR) TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""; echo -e "  │→ TG 通知: \033[32m已清除（不启用）\033[0m" ;;
            "") echo -e "  │→ TG 通知: \033[32m保留已启用\033[0m" ;;
            *) echo "提示：更换 TG 请用 4) 修改配置 或 set-tg，此处仅保留/清除。" ;;
        esac
    else
        printf "TG Bot Token (留空不启用): "; read -r _nt
        printf "TG Chat ID (留空不启用): "; read -r _nc
        if [ -n "$_nt" ] && [ -n "$_nc" ]; then
            TELEGRAM_BOT_TOKEN="$_nt"; TELEGRAM_CHAT_ID="$_nc"
            echo -e "  │→ TG 通知: \033[32m已启用\033[0m"
        elif [ -n "$_nt" ] || [ -n "$_nc" ]; then
            echo "TG 凭据不完整（需同时填写），本次不启用。"
            TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
        else
            echo -e "  │→ TG 通知: \033[32m不启用\033[0m"
        fi
    fi
    printf "日志保留天数 [%s]: " "$_d_log"; read -r v || return 1
    case "$v" in
        "") LOG_RETENTION_DAYS="$_d_log" ;;
        -1|0) LOG_RETENTION_DAYS="$v" ;;
        *[!0-9]*) echo "无效天数，用默认值 $_d_log。" ; LOG_RETENTION_DAYS="$_d_log" ;;
        *) LOG_RETENTION_DAYS="$v" ;;
    esac
    if [ "$LOG_RETENTION_DAYS" = "0" ] || [ "$LOG_RETENTION_DAYS" = "-1" ]; then
        echo -e "  │→ 日志保留: \033[32m保留全部\033[0m"
    else
        echo -e "  │→ 日志保留: \033[32m${LOG_RETENTION_DAYS} 天\033[0m"
    fi
    echo ""
    _tg_show="未启用"
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && _tg_show="已启用"
    echo "确认安装参数：平台=$PLATFORM 上限=${LIMIT}GB 口径=$STAT_MODE SSH=$SSH_PORT DNS=${DNS_SERVERS:-自动} TG=$_tg_show 日志保留=$LOG_RETENTION_DAYS 天"
    printf "开始安装？(y/N): "; read -r a || return 1
    case "$a" in y|Y|yes|YES) return 0 ;; *) echo "-> 已取消。" ; return 1 ;; esac
}
# 查看流量：直接跑运行时 check 脚本（查当月上下行 + 超限判定 + 封网；未部署时提示）
menu_check() {
    if [ -x "$SCRIPT_DIR/check_traffic.sh" ]; then
        bash "$SCRIPT_DIR/check_traffic.sh"
    elif [ -x /root/traffic_routing/check_traffic.sh ]; then
        bash /root/traffic_routing/check_traffic.sh
    else
        echo "未找到 check_traffic.sh，请先部署（菜单 1）。"
    fi
}
# 恢复网络：直接跑运行时 reset 脚本（清封网 + 重置统计 + 归档；未部署时提示）
menu_restore() {
    if [ -x "$SCRIPT_DIR/reset_network.sh" ]; then
        bash "$SCRIPT_DIR/reset_network.sh"
    elif [ -x /root/traffic_routing/reset_network.sh ]; then
        bash /root/traffic_routing/reset_network.sh
    else
        echo "未找到 reset_network.sh，请先部署（菜单 1）。"
    fi
}
# 脚本更新：从 GitHub 拉最新部署器，校验后覆盖 $0 与落盘副本、重建 tfc 链接，
# 并自动重装以重生成 check/reset/netstat（配置/conf/cron 保留，即时生效）；可重复执行
menu_update() {
    _url="${UPDATE_URL:-https://raw.githubusercontent.com/jyucoeng/gcp_traffic_routing/main/netMonitor/traffic_ctrl.sh}"
    _tmp="/tmp/traffic_ctrl.new"
    echo "--> 正在下载最新脚本..."
    if ! wget -O "$_tmp" "$_url" 2>&1 | tail -n2; then
        echo "错误：下载失败（封网断外网时请先恢复网络，或检查 UPDATE_URL）。" >&2
        rm -f "$_tmp"
        return 1
    fi
    [ -s "$_tmp" ] || { echo "错误：下载文件为空。" >&2; rm -f "$_tmp"; return 1; }
    bash -n "$_tmp" 2>/dev/null || { echo "错误：新脚本语法校验未通过，已丢弃。" >&2; rm -f "$_tmp"; return 1; }
    # 更新判定：SHA 为主（任何内容变化都检出），版本号为辅（展示用）；
    # 本地对照文件优先用落盘副本（SCRIPT_DIR/traffic_ctrl.sh），回退 $0
    _local_f="$SCRIPT_DIR/traffic_ctrl.sh"
    case "$0" in
        /dev/fd/*|/proc/self/fd/*) : ;;
        *) [ -f "$_local_f" ] || { [ -f "$0" ] && _local_f="$0"; } ;;
    esac
    _local_v="${VERSION:-unknown}"
    _remote_v="$(grep -m1 -oE 'VERSION:-v[0-9.]+' "$_tmp" 2>/dev/null | grep -oE 'v[0-9.]+' | head -n1)"
    [ -n "$_remote_v" ] || _remote_v="unknown"
    if [ -f "$_local_f" ] && { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; }; then
        if command -v sha256sum >/dev/null 2>&1; then
            _local_sha="$(sha256sum "$_local_f" 2>/dev/null | awk '{print $1}')"
            _remote_sha="$(sha256sum "$_tmp" 2>/dev/null | awk '{print $1}')"
        else
            _local_sha="$(shasum -a 256 "$_local_f" 2>/dev/null | awk '{print $1}')"
            _remote_sha="$(shasum -a 256 "$_tmp" 2>/dev/null | awk '{print $1}')"
        fi
        if [ -n "$_local_sha" ] && [ "$_local_sha" = "$_remote_sha" ]; then
            echo "--> 已是最新（SHA 一致，$_local_v），无需更新。"
            rm -f "$_tmp"
            return 0
        fi
        if [ "$_local_v" = "$_remote_v" ]; then
            echo "--> 发现内容更新（同版本 hotfix，$_local_v，SHA 不一致），正在更新..."
        else
            echo "--> 发现新版本：$_local_v -> $_remote_v，正在更新..."
        fi
    else
        # 无 sha256sum 时回退纯版本号比较
        if [ "$_local_v" = "$_remote_v" ]; then
            echo "--> 已是最新版本（$_local_v），无需更新。"
            rm -f "$_tmp"
            return 0
        fi
        echo "--> 发现新版本：$_local_v -> $_remote_v，正在更新..."
    fi
    case "$0" in
        /dev/fd/*|/proc/self/fd/*) : ;;
        *) [ -f "$0" ] && cp -f "$_tmp" "$0" ;;
    esac
    mkdir -p "$SCRIPT_DIR"
    cp -f "$_tmp" "$SCRIPT_DIR/traffic_ctrl.sh"
    chmod +x "$SCRIPT_DIR/traffic_ctrl.sh"
    [ -f "$0" ] && [ "$0" != "$SCRIPT_DIR/traffic_ctrl.sh" ] && chmod +x "$0" 2>/dev/null || true
    mkdir -p /usr/local/bin 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/traffic_ctrl.sh" "/usr/local/bin/${TFC_NAME:-tfc}"
    rm -f "$_tmp"
    echo "--> 脚本已更新（部署器 + ${TFC_NAME:-tfc} 链接），正在用原配置重装以重生成运行时..."
    # 用原 conf 重装：读出原配置逐项透传（含 LIMIT/TG 明文解密），conf 缺失则提示手动安装
    if [ -f "$CONF_FILE" ]; then
        . "$CONF_FILE"
        # dec_tg 在外层部署器可用；新脚本同名函数行为一致，直接复用
        _tg_t="$(printf '%s\n' "${TELEGRAM_BOT_TOKEN_ENC:-}" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"${NETMON_KEY:-$CONF_DIR/netMonitor.key}" 2>/dev/null)"
        _tg_c="$(printf '%s\n' "${TELEGRAM_CHAT_ID_ENC:-}" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"${NETMON_KEY:-$CONF_DIR/netMonitor.key}" 2>/dev/null)"
        PLATFORM="${PLATFORM:-gcp}" LIMIT="${LIMIT:-}" STAT_MODE="${STAT_MODE:-sum}" SSH_PORT="${SSH_PORT:-22}" \
        DNS_SERVERS="$DNS_SERVERS" LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}" \
        TELEGRAM_BOT_TOKEN="$_tg_t" TELEGRAM_CHAT_ID="$_tg_c" \
        SCRIPT_DIR="$SCRIPT_DIR" CONF_DIR="$CONF_DIR" CONF_FILE="$CONF_FILE" \
        NETMON_KEY="$NETMON_KEY" TFC_NAME="${TFC_NAME:-tfc}" KEEP_TRAFFIC=1 \
        bash "$SCRIPT_DIR/traffic_ctrl.sh" req
    else
        echo "--> 未找到 ${CONF_FILE}，跳过重装；正在重载新版菜单..."
        exec bash "$SCRIPT_DIR/traffic_ctrl.sh" menu
    fi
}
# 一级菜单网络状态行：绿●正常 / 红■封网中 / 黄○未部署（读 state + 防火墙跳转数）
menu_net_status() {
    _conf="${CONF_FILE:-/etc/traffic_routing/netMonitor.conf}"
    _state="/var/lib/traffic_monitor/state"
    if [ ! -f "$_conf" ]; then
        printf '\033[33m○ 未部署\033[0m'
        return 0
    fi
    _st="normal"
    [ -f "$_state" ] && _st="$(sed -n 's/^STATE=//p' "$_state" 2>/dev/null | tail -n1)"
    [ -n "$_st" ] || _st="normal"
    _fw=0
    if command -v iptables >/dev/null 2>&1; then
        _fw="$(iptables -L INPUT -n 2>/dev/null | grep -c TRAFFIC_BLOCKED)"
    fi
    if [ "$_st" = "blocked" ] || [ "${_fw:-0}" -gt 0 ] 2>/dev/null; then
        printf '\033[31m■ 封网中\033[0m（超限，SSH/DNS 可用）'
    else
        printf '\033[32m● 正常\033[0m'
    fi
}
# 菜单停顿：子操作完成后停住，按任意键回菜单（非交互 stdin 下直接回菜单）；
# 子函数 exit 会终结整个菜单进程，故调用处统一加 || true 兜底
menu_pause() {
    printf "\033[32m按任意键返回菜单...\033[0m"
    read -r -n1 _k < /dev/tty 2>/dev/null || read -r _k 2>/dev/null || true
    echo ""
}
main_menu() {
    require_root
    while :; do
        echo ""
        menu_header
        echo " 1) 安装"
        echo " 2) 覆盖安装"
        echo " 3) 查看当前配置"
        echo " 4) 修改配置（交互菜单，含 TG）"
        echo " 5) 查看流量"
        echo " 6) 恢复网络"
        echo " 7) 脚本更新"
        echo " 8) 重置本月 TG 发送计数"
        echo " 9) 卸载"
        echo " 0) 退出"
        echo "========================="
        printf "请选择: "
        read -r opt || break

        case "$opt" in
            1)
                if [ -f "${CONF_FILE:-/etc/traffic_routing/netMonitor.conf}" ]; then
                    echo "检测到已有部署，如需覆盖请选 2) 覆盖安装。"
                else
                    menu_install_ask 1 && do_install || true
                fi
                menu_pause
                ;;
            2)
                menu_install_ask 2 && do_install || true
                menu_pause
                ;;
            3)
                config_show || true
                menu_pause
                ;;
            4)
                config_edit || true
                ;;
            5)
                menu_check || true
                menu_pause
                ;;
            6)
                printf "确认恢复网络？将清除封网规则并重置当月统计 (y/N): "; read -r a
                case "$a" in
                    y|Y|yes|YES) menu_restore || true ;;
                    *) echo "-> 已取消。" ;;
                esac
                menu_pause
                ;;
            7)
                menu_update || true
                menu_pause
                ;;
            8)
                printf "确认重置本月 TG 发送计数？超限/恢复通知可重新各发 1 条 (y/N): "; read -r a
                case "$a" in
                    y|Y|yes|YES) tg_notify_reset || true ;;
                    *) echo "-> 已取消。" ;;
                esac
                menu_pause
                ;;
            9)
                printf "确认卸载？封网规则与部署物将被清理，密钥与月度档案保留 (y/N): "; read -r a
                case "$a" in
                    y|Y|yes|YES) uninstall || true ;;
                    *) echo "-> 已取消。" ;;
                esac
                menu_pause
                ;;
            0|q|Q)
                echo -e "\033[32m感谢使用本脚本，再见👋\033[0m"
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# ---------------- 子命令：usage ----------------
print_usage() {
    cat <<'EOF'
用法: bash traffic_ctrl.sh [命令]

命令:
  (无参数)         进入管理菜单（默认）
  menu             显示管理菜单
  req              部署 / 重新部署
  edit             交互式修改配置（平台/上限/口径/端口/DNS/TG/日志保留）
  config           查看当前配置（TG 凭据掩码显示）
  set-tg           更换 TG 凭据：TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy
  clear-tg         停用并清除 TG 凭据
  check            查看流量（跑 check_traffic.sh：查当月上下行 + 超限判定）
  restore          恢复网络（跑 reset_network.sh：清封网 + 重置统计）
  update           脚本更新（从 GitHub 拉最新部署器，仅换文件不重装）
  reset-notify     重置本月 TG 发送计数（删 notify 本月行，超限/恢复可重发）
  del              卸载
  -h | --help | help  显示本帮助

环境变量:
  PLATFORM / LIMIT / STAT_MODE / SSH_PORT / DNS_SERVERS
  LOG_RETENTION_DAYS / SCRIPT_DIR / CONF_DIR / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID
EOF
}

# ==========================================
# 以下为完整部署流程（do_install：req 子命令 / 菜单项 1 调用）
# ==========================================
do_install() {
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

# 1. 自动获取默认网卡名称（纯自动探测，不再接受手动指定；先 IPv4 默认路由，失败则回退 IPv6）
INTERFACE=$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -6 route 2>/dev/null | grep '^default' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)
fi

if [ -z "$INTERFACE" ]; then
    echo "错误：无法自动检测到网卡名称（本脚本为纯自动探测，不再接受手动指定 INTERFACE）。" >&2
    exit 1
fi

# LIMIT 无默认值：未显式设置则直接报错（避免误用平台推断上限）
if [ -z "${LIMIT:-}" ]; then
    echo "错误：未设置 LIMIT（流量上限 GB）。请显式指定，例如：LIMIT=180 bash $0；0/-1 表示无限制。" >&2
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
        return 1
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
        return 1
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

# 2.9 提前创建运行时脚本目录（check/reset/netstat 三个脚本统一收拢于此）
mkdir -p "$SCRIPT_DIR"

# 3. 生成独立流量统计脚本 ($SCRIPT_DIR/netstat.sh)
#    算法与哪吒探针(nezha)一致：直接读 /proc/net/dev，排除虚拟网卡(lo/docker/veth/br-等)，
#    对剩余全部物理网卡的 RX(下行)/TX(上行) 分别求和作为"当前累计"；
#    通过与上次快照求差得到增量，分别累加到当月 RX/TX 累计
#   （快照回绕/服务器重启时增量归零重新累计），彻底摆脱对 vnstatd 的依赖。
#    供下方 heredoc 展开的绝对路径（check/reset 内统计调用统一用此变量）
NETSTAT_BIN="$SCRIPT_DIR/netstat.sh"
echo "--> 生成独立流量统计脚本 $SCRIPT_DIR/netstat.sh..."
cat > "$SCRIPT_DIR/netstat.sh" <<'NETSTAT'
#!/bin/bash
# netstat.sh - 独立流量统计 (nezha 式 /proc/net/dev + 月度增量, 上下行分开)
# 用法（与 SCRIPT_DIR 同目录，默认 /root/traffic_routing/netstat.sh）:
#   netstat.sh            输出当月累计字节: "上行(TX) 下行(RX)" (空格分隔, 两值)
#   netstat.sh --out       只输出当月上行累计 (单值)
#   netstat.sh --in       只输出当月下行累计 (单值)
#   netstat.sh --reset    清零当月累计 (每月1号由 reset_network.sh 调用)
#   netstat.sh --current  输出当前网卡累计快照 (调试用)
#   每次调用都是"采样"：会推进快照、更新/持久化状态。状态文件: /var/lib/traffic_monitor/netcount

set -u
STATE_DIR="/var/lib/traffic_monitor"
COUNT_FILE="$STATE_DIR/netcount"
CUR_MONTH=$(date '+%Y-%m')

# 读 /proc/net/dev, 对所有"非虚拟"网卡分别按 RX(第2列) / TX(第10列) 求和
# 输出: "<TX累计> <RX累计>"
current_counters() {
    awk '
        /^[[:space:]]*[a-zA-Z0-9_@.-]+:/ {
            iface=$1; sub(/:/,"",iface)
            if (iface=="lo" || iface ~ /^docker/ || iface ~ /^veth/ || iface ~ /^br-/ \
                || iface ~ /^virbr/ || iface ~ /^tun/ || iface ~ /^tap/ || iface ~ /^vbox/ \
                || iface ~ /^dummy/) next
            out += $10
            rxcnt += $2
        }
        END { printf "%.0f %.0f\n", out+0, rxcnt+0 }
    ' /proc/net/dev
}

mkdir -p "$STATE_DIR"
read -r CUR_TX CUR_RX <<< "$(current_counters)"

# 读取上次状态
LAST_TX=0; LAST_RX=0; MONTH_TX=0; MONTH_RX=0; MONTH=""
[ -f "$COUNT_FILE" ] && . "$COUNT_FILE"

# 跨月: 清零当月累计 (新计费周期), 快照保留为下次 delta 基准
if [ "$MONTH" != "$CUR_MONTH" ]; then
    MONTH_TX=0
    MONTH_RX=0
    MONTH="$CUR_MONTH"
fi

if [ "${1:-}" = "--reset" ]; then
    MONTH_TX=0
    MONTH_RX=0
    MONTH="$CUR_MONTH"
    LAST_TX=$CUR_TX
    LAST_RX=$CUR_RX
    cat > "$COUNT_FILE" <<EOF
MONTH=$MONTH
MONTH_TX=$MONTH_TX
MONTH_RX=$MONTH_RX
LAST_TX=$LAST_TX
LAST_RX=$LAST_RX
EOF
    echo "0 0"
    exit 0
fi

# 求增量: 快照回绕(重启)时 delta 归零重计, 与 nezha min() 语义一致 (上下行独立)
if [ "$LAST_TX" -eq 0 ] || [ "$CUR_TX" -lt "$LAST_TX" ]; then
    DELTA_TX=$CUR_TX
else
    DELTA_TX=$(( CUR_TX - LAST_TX ))
fi
if [ "$LAST_RX" -eq 0 ] || [ "$CUR_RX" -lt "$LAST_RX" ]; then
    DELTA_RX=$CUR_RX
else
    DELTA_RX=$(( CUR_RX - LAST_RX ))
fi
MONTH_TX=$(( MONTH_TX + DELTA_TX ))
MONTH_RX=$(( MONTH_RX + DELTA_RX ))
LAST_TX=$CUR_TX
LAST_RX=$CUR_RX

cat > "$COUNT_FILE" <<EOF
MONTH=$MONTH
MONTH_TX=$MONTH_TX
MONTH_RX=$MONTH_RX
LAST_TX=$LAST_TX
LAST_RX=$LAST_RX
EOF

case "${1:-}" in
    --out) echo "$MONTH_TX" ;;
    --in) echo "$MONTH_RX" ;;
    --current) current_counters ;;
    *)    echo "$MONTH_TX $MONTH_RX" ;;
esac
NETSTAT
chmod +x "$SCRIPT_DIR/netstat.sh"
# 快照初始化：全新部署时 --reset（当月累计=0、快照=当前累计）；
# 覆盖重装/脚本更新时（KEEP_TRAFFIC=1）只刷新快照不归零，当月累计延续
if [ "${KEEP_TRAFFIC:-0}" = "1" ] && [ -f /var/lib/traffic_monitor/netcount ]; then
    "$SCRIPT_DIR/netstat.sh" >/dev/null 2>&1 || true
    echo "--> 流量统计脚本已生成（当月累计保留，仅刷新快照）。"
else
    "$SCRIPT_DIR/netstat.sh" --reset >/dev/null 2>&1 || true
    echo "--> 流量统计脚本已生成并初始化 (独立于 vnstat)。"
fi

# 3.5 生成运行时配置文件与密钥
gen_key
write_conf
echo "--> 运行时配置已写入 ${CONF_FILE}（密钥 ${NETMON_KEY}，TG 凭据已加密）。"

# 4. 生成监控脚本 ($SCRIPT_DIR/check_traffic.sh)
#    配置统一从 CONF_FILE 读取（改配置不改脚本）。
echo "--> 生成监控脚本 $SCRIPT_DIR/check_traffic.sh..."
cat > "$SCRIPT_DIR/check_traffic.sh" <<EOF
#!/bin/bash

# 强制使用标准区域设置
export LC_ALL=C

# 配置来源：改 conf 文件即生效（无需重部署）；SCRIPT_DIR 部署期 baked，check 与 netstat 同目录
CONF_FILE="$CONF_FILE"
NETMON_KEY="$NETMON_KEY"
SCRIPT_DIR="$SCRIPT_DIR"
LOG_FILE="/var/log/traffic_monitor.log"
STATE_FILE="/var/lib/traffic_monitor/state"
# TG 发送历史：独立文件，一行一月 (UTC 时间戳)，check/reset 共用；
# 格式: YYYY-MM OVER=<UTC|-> RESTORE=<UTC|-> (例: 2026-09 OVER=2026-09-19T02:40:00Z RESTORE=-)
# 每月各最多 1 条的判定依据；与 state 分离存放 —— 删 state / 覆盖重装 / 回落都不清零；
# 只保留最近 12 个月记录，删文件即手工重置当月限制
NOTIFY_FILE="/var/lib/traffic_monitor/notify"

# 读取运行时配置
if [ -r "\$CONF_FILE" ]; then
    . "\$CONF_FILE"
else
    echo "错误：缺少配置文件 \$CONF_FILE" >&2
    exit 1
fi

# 当月超限通知是否已发送 (兼容第一代 OVER_MONTH= 变量行)
notify_over_sent() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    [ -f "\$NOTIFY_FILE" ] || return 1
    grep -q "^OVER_MONTH=\$CUR_MONTH\$" "\$NOTIFY_FILE" 2>/dev/null && return 0
    _line="\$(grep -E "^\$CUR_MONTH[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
    [ -n "\$_line" ] || return 1
    _v=""
    for _f in \$_line; do
        case "\$_f" in
            OVER=*) _v="\${_f#OVER=}"; break ;;
        esac
    done
    [ -n "\$_v" ] && [ "\$_v" != "-" ]
}

# 当月恢复通知是否已发送 (兼容第一代 RESTORE_MONTH= 变量行)
notify_restore_sent() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    [ -f "\$NOTIFY_FILE" ] || return 1
    grep -q "^RESTORE_MONTH=\$CUR_MONTH\$" "\$NOTIFY_FILE" 2>/dev/null && return 0
    _line="\$(grep -E "^\$CUR_MONTH[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
    [ -n "\$_line" ] || return 1
    _v=""
    for _f in \$_line; do
        case "\$_f" in
            RESTORE=*) _v="\${_f#RESTORE=}"; break ;;
        esac
    done
    [ -n "\$_v" ] && [ "\$_v" != "-" ]
}

# 记一条发送历史 (UTC 时间戳)：\$1=OVER|RESTORE；输出本次时间戳；只保留最近 12 个月
notify_mark() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    _type="\$1"
    _ts="\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    _m="\$CUR_MONTH"
    mkdir -p "\$(dirname "\$NOTIFY_FILE")"
    _tmp="\${NOTIFY_FILE}.tmp"
    _old_over="-"; _old_restore="-"
    if [ -f "\$NOTIFY_FILE" ]; then
        _oldline="\$(grep -E "^\${_m}[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
        if [ -n "\$_oldline" ]; then
            for _f in \$_oldline; do
                case "\$_f" in
                    OVER=*) _old_over="\${_f#OVER=}" ;;
                    RESTORE=*) _old_restore="\${_f#RESTORE=}" ;;
                esac
            done
            [ -n "\$_old_over" ] || _old_over="-"
            [ -n "\$_old_restore" ] || _old_restore="-"
        fi
        grep -Ev '^(OVER_MONTH|RESTORE_MONTH|OVER_TIME|RESTORE_TIME)=' "\$NOTIFY_FILE" 2>/dev/null | grep -Ev "^\${_m}[[:space:]]" > "\$_tmp" 2>/dev/null || : > "\$_tmp"
    else
        : > "\$_tmp"
    fi
    case "\$_type" in
        OVER) _old_over="\$_ts" ;;
        RESTORE) _old_restore="\$_ts" ;;
    esac
    printf '%s OVER=%s RESTORE=%s\n' "\$_m" "\${_old_over:--}" "\${_old_restore:--}" >> "\$_tmp"
    sort -k1,1 "\$_tmp" 2>/dev/null | tail -n 12 > "\$NOTIFY_FILE" 2>/dev/null || tail -n 12 "\$_tmp" > "\$NOTIFY_FILE"
    rm -f "\$_tmp"
    printf '%s' "\$_ts"
}

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
# LIMIT 无默认值：空/0/-1 = 无限制（check 内跳过封网判定）；只在 >0 时比较
if [ -z "\${LIMIT:-}" ]; then
    LIMIT=""
fi

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
    local geo ip city cc loc masked ipv4 ipv6
    geo=""
    # 双栈分别取：v4 走 ip-api（带定位），v6 走 ipwho.is/ipify（仅地址）；
    # 单栈只取对应族；本机IP行按族拼接（双栈显示两个，单栈显示一个）
    ipv4=""; ipv6=""
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

    # 主 IP 归族：v4 格式进 ipv4，v6（含 ::）进 ipv6
    case "\$ip" in
        "") : ;;
        *:* ) ipv6="\$ip" ;;
        *) ipv4="\$ip" ;;
    esac

    # 定位互补：主查询无定位（v4 被墙/CF 盖住/unknown）且双栈时，用另一族补一次定位；
    # 通知在封网前/解封后发送，此时外网可用，多一次请求可接受
    if [ -z "\$city$cc" ] || [ "\$cc" = "unknown" ]; then
        _geo2=""
        case "\$ip" in
            *:* )
                [ "\$HAS_V4" = "1" ] && _geo2=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null) ;;
            *)
                [ "\$HAS_V6" = "1" ] && _geo2=\$(curl -6 -s --max-time 5 "https://ipwho.is/" 2>/dev/null) ;;
        esac
        if [ -n "\$_geo2" ]; then
            _c2=\$(echo "\$_geo2" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
            _cc2=\$(echo "\$_geo2" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
            [ -z "\$_cc2" ] && _cc2=\$(echo "\$_geo2" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')
            [ -n "\$_c2" ] && city="\$_c2"
            [ -n "\$_cc2" ] && cc="\$_cc2"
        fi
    fi

    # 双栈补取另一族地址：v4 已有则补 v6（ipify v6），v6 已有则补 v4（ipify v4）
    if [ "\$HAS_V6" = "1" ] && [ -z "\$ipv6" ]; then
        ipv6=\$(curl -6 -s --max-time 5 "https://api64.ipify.org" 2>/dev/null)
    fi
    if [ "\$HAS_V4" = "1" ] && [ -z "\$ipv4" ]; then
        ipv4=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi
    # 外部查询全部失败时 (如封网断外网) 回退用本机网卡地址, 保证 IP 不至于空白
    if [ -z "\$ipv4" ] && [ "\$HAS_V4" = "1" ]; then
        ipv4=\$(ip -4 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
    fi
    if [ -z "\$ipv6" ] && [ "\$HAS_V6" = "1" ]; then
        ipv6=\$(ip -6 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1 | cut -d% -f1)
    fi

    # 拼接展示：双栈 "v4 / v6"，单栈单个；masked 与 ip 同值（当前不打码）
    if [ -n "\$ipv4" ] && [ -n "\$ipv6" ]; then
        masked="\$ipv4 / \$ipv6"
        ip="\$ipv4 / \$ipv6"
    elif [ -n "\$ipv4" ]; then
        masked="\$ipv4"
        ip="\$ipv4"
    else
        masked="\$ipv6"
        ip="\$ipv6"
    fi

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
# 读取当月上下行累计 (调用一次 netstat.sh = 一次采样)
# 数据来源: 独立统计脚本 $SCRIPT_DIR/netstat.sh (nezha 式 /proc/net/dev + 月度增量, 上下行分开)
# 注意: netstat.sh 每次调用都会推进快照，必须只调用一次并把结果复用，
#       否则同一 cron 周期多次采样会导致累计翻倍。
# 设置: MONTH_TX / MONTH_RX (字节), 并按 STAT_MODE 计算 BAL_BYTES (超限判断口径)
#   STAT_MODE: out=出站 in=入站 max=取大 min=取小 sum=总和
# ==========================================
NETSTAT_BIN="\$SCRIPT_DIR/netstat.sh"
read_traffic() {
    local out
    out=\$("$NETSTAT_BIN" 2>/dev/null)
    # 输出格式: "上行(TX) 下行(RX)" 两值空格分隔
    MONTH_TX=\${out%% *}
    MONTH_RX=\${out##* }
    if ! [[ "\$MONTH_TX" =~ ^[0-9]+$ ]]; then MONTH_TX=0; fi
    if ! [[ "\$MONTH_RX" =~ ^[0-9]+$ ]]; then MONTH_RX=0; fi
    case "\$STAT_MODE" in
        in)  BAL_BYTES=\$MONTH_RX ;;
        max) [ "\$MONTH_TX" -ge "\$MONTH_RX" ] && BAL_BYTES=\$MONTH_TX || BAL_BYTES=\$MONTH_RX ;;
        min) [ "\$MONTH_TX" -le "\$MONTH_RX" ] && BAL_BYTES=\$MONTH_TX || BAL_BYTES=\$MONTH_RX ;;
        sum) BAL_BYTES=\$(( MONTH_TX + MONTH_RX )) ;;
        *)   BAL_BYTES=\$MONTH_TX ;;
    esac
}

# ==========================================
# 流量格式化: 按 MB -> GB -> TB 层级递进
# 输入: 字节数  输出: 如 512.00MB / 123.45GB / 1.23TB
# 规则: <1GB 用 MB; 1GB~1024GB 用 GB; >=1024GB 用 TB
# ==========================================
# 小数补前导 0: bc 输出如 .65 时补成 0.65 (终端/TG/日志统一正常显示)
fmt_fix() {
    case "\$1" in
        .*) echo "0\$1" ;;
        *)  echo "\$1" ;;
    esac
}
format_traffic() {
    local bytes b
    bytes="\$1"
    case "\$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    b=\$(echo "scale=2; \$bytes / 1073741824" | bc)   # 换算成 GB
    if [ \$(echo "\$b < 1" | bc) -eq 1 ]; then
        # 不足 1GB -> MB
        echo "\$(fmt_fix "\$(echo "scale=2; \$bytes / 1048576" | bc)")MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        # 1GB ~ 1024GB -> GB
        echo "\$(fmt_fix "\${b}")GB"
    else
        # >= 1024GB (1TB) -> TB
        echo "\$(fmt_fix "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)")TB"
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
# 读取一次当月上下行累计 (单次采样, 含 STAT_MODE 计费口径计算)
# ==========================================
read_traffic

# 计费口径换算成 GB (1 GB = 1073741824 Bytes)
BAL_GB=\$(echo "scale=2; \$BAL_BYTES / 1073741824" | bc)

# 上限括号换算：与 TG 超限通知同逻辑，按计费流量单位换算上限
# （例：计费 8.07MB / 上限 500GB -> 流量上限: 500 GB (512000.00MB)）
BAL_FMT="\$(format_traffic "\$BAL_BYTES")"
BAL_UNIT="\$(printf '%s' "\$BAL_FMT" | grep -oE 'MB|GB|TB' | tail -n1)"
LIMIT_DISPLAY_TERM="\$LIMIT GB"
if [ -n "\${LIMIT:-}" ] && [ "\$LIMIT" != "0" ] && [ "\$LIMIT" != "-1" ] && [ -n "\$BAL_UNIT" ] && [ "\$BAL_UNIT" != "GB" ]; then
    LIMIT_BYTES_TERM=\$(echo "scale=0; \$LIMIT * 1073741824 / 1" | bc 2>/dev/null)
    case "\$BAL_UNIT" in
        MB) LIMIT_DIV_TERM=1048576 ;;
        TB) LIMIT_DIV_TERM=1099511627776 ;;
        *)  LIMIT_DIV_TERM=1073741824 ;;
    esac
    case "\$LIMIT_BYTES_TERM" in ''|*[!0-9]*) : ;; *)
        LIMIT_CONV_TERM="\$(fmt_fix "\$(echo "scale=2; \$LIMIT_BYTES_TERM / \$LIMIT_DIV_TERM" | bc)") \$BAL_UNIT"
        LIMIT_DISPLAY_TERM="\$LIMIT GB (\$LIMIT_CONV_TERM)" ;;
    esac
fi

# ==========================================
# 1. 终端直接输出 (显示精确数值)
# ==========================================
echo "========================================"
echo " 网卡接口    : \$INTERFACE"
echo " 当前时间    : \$(date '+%Y-%m-%d %H:%M:%S')"
echo " 上行出站(TX): \$(format_traffic "\$MONTH_TX") (\$MONTH_TX Bytes)"
echo " 下行入站(RX): \$(format_traffic "\$MONTH_RX") (\$MONTH_RX Bytes)"
echo " 计费口径    : \$STAT_MODE (out=出站 in=入站 max=取大 min=取小 sum=总和)"
echo " 已用流量    : \$(format_traffic "\$BAL_BYTES") (\$BAL_BYTES Bytes)"
echo " 流量上限    : \$LIMIT_DISPLAY_TERM"
echo "========================================"

# ==========================================
# 2. 日志记录与限制逻辑
# ==========================================

log "当前计费流量(\$STAT_MODE): \$(format_traffic "\$BAL_BYTES") / 上限: \$LIMIT GB (上行 \$(format_traffic "\$MONTH_TX") / 下行 \$(format_traffic "\$MONTH_RX"))"

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

# 保存当月状态到文件（附带本次判定的快照：流量口径/上限/上下行/计费流量，
# 看 state 一眼可知：这个月用了多少、是否断网、口径和上限是多少）
save_state() {
    mkdir -p "\$(dirname "\$STATE_FILE")"
    cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME="\$BLOCKED_TIME"
BLOCKED_TX="\$BLOCKED_TX"
RESTORED_TIME="\$RESTORED_TIME"
USED_STAT_MODE=\$STAT_MODE
USED_LIMIT=\$LIMIT
USED_TX=\$MONTH_TX
USED_RX=\$MONTH_RX
USED_BAL=\$BAL_BYTES
STATE_EOF
}

# 检查是否超限 (用字节级精度比较, 支持 GB 小数上限如 0.001=1MB, 避免 BAL_GB 浮点取整误判)
# LIMIT 语义: 未设置/空/0/-1 = 无限制（跳过封网判定）；>0 才做超限比较
if [ -z "\${LIMIT:-}" ] || [ "\$LIMIT" = "0" ] || [ "\$LIMIT" = "-1" ]; then
    echo "状态: [无限制] LIMIT 未设置或为 0/-1，本次不做超限判定。"
    log "LIMIT 未设置(0/-1=无限制)，跳过超限判定 (上行 \$(format_traffic "\$MONTH_TX") / 下行 \$(format_traffic "\$MONTH_RX"))。"
    STATE=normal
    save_state
else
LIMIT_BYTES=\$(echo "scale=0; \$LIMIT * 1073741824 / 1" | bc)
if [ \$(echo "\$BAL_BYTES >= \$LIMIT_BYTES" | bc) -eq 1 ]; then
    echo "状态: [警告] 流量已超限，正在禁止出站..."
    log "警告：流量超出限制！正在执行封网策略 (双向封锁)..."

    # ---- 超限通知：每月最多 1 条 (以 NOTIFY_FILE 的 OVER_MONTH 为准) ----
    # 状态机照常翻转 (STATE=blocked + 封网每次都执行)，但 TG 只在当月未发送过时才发；
    # 删 state / 覆盖重装 / 回落再超限都不重发，须手动删 NOTIFY_FILE 才重置
    if [ "\$STATE" != "blocked" ]; then
        STATE=blocked
        BLOCKED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
        BLOCKED_TX="\$BAL_BYTES"
        save_state
    fi
    if [ "\$STATE" = "blocked" ]; then
        # 超限时发送 TG 通知 (TG 启用且当月未发送过时；标记以 notify 历史为准)
        if [ "\$TG_ON" = "1" ] && ! notify_over_sent; then
            IFS='|' read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
            # CPU 行 (仅 oracle 显示)
            CPU_LINE=""
            if is_oracle_platform; then
                CPU_LINE="
🧠 CPU: \$(get_cpu_type)"
            fi

            # 已用流量(计费口径 BAL)及其显示单位; 上限若与已用流量单位不同, 追加换算值 (如 上限: 0.0001 GB (0.10MB))
            # 口径中文名: sum-总和 / out-出站 / in-入站 / max-取大 / min-取小
            case "\$STAT_MODE" in
                out) STAT_LABEL="out-出站" ;;
                in)  STAT_LABEL="in-入站" ;;
                max) STAT_LABEL="max-取大" ;;
                min) STAT_LABEL="min-取小" ;;
                *)   STAT_LABEL="sum-总和" ;;
            esac
            USED_FMT="\$(format_traffic "\$BAL_BYTES")"
            USED_UNIT="\$(printf '%s' "\$USED_FMT" | grep -oE 'MB|GB|TB' | tail -n1)"
            LIMIT_DISPLAY="\$LIMIT GB"
            if [ -n "\$USED_UNIT" ] && [ "\$USED_UNIT" != "GB" ]; then
                case "\$USED_UNIT" in
                    MB) LIMIT_DIV=1048576 ;;
                    TB) LIMIT_DIV=1099511627776 ;;
                    *)  LIMIT_DIV=1073741824 ;;
                esac
                LIMIT_CONV="\$(fmt_fix "\$(echo "scale=2; \$LIMIT_BYTES / \$LIMIT_DIV" | bc)") \$USED_UNIT"
                LIMIT_DISPLAY="\$LIMIT GB (\$LIMIT_CONV)"
            fi

            # 组装通知文本 (oracle 时含 CPU 行); 运行时间在组装消息时(发送前最后一刻)才取, 尽量接近实际发送时刻
            # 版式: 口径中文名 + 上限(括号内自动换算同单位)一行; 已用流量 + 上行/下行一行
TG_MSG="🎮 \$PLATFORM 流量报告（流量超限通知）

📍 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$(TZ='UTC-8' date '+%Y-%m-%d %H:%M:%S')
📚 网络状态: 正常 ---> 超限(双向封网)
📊 计费口径: \$STAT_LABEL / 上限: \$LIMIT_DISPLAY
🌐 已用流量: \$USED_FMT / (上行 \$(format_traffic "\$MONTH_TX") / 下行 \$(format_traffic "\$MONTH_RX"))\${CPU_LINE}"

            tg_send "\$TG_MSG"
            OVER_TS="\$(notify_mark OVER)"
            log "已发送流量超限 TG 通知 (\$OVER_TS)。"
        else
            if [ "\$TG_ON" != "1" ]; then
                log "TG 未启用，跳过超限通知。"
            else
                echo "    (本月已发送超限通知，跳过。)"
                log "本月已发送超限通知，跳过 (见 \$NOTIFY_FILE)。"
            fi
        fi
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
        # 幂等去重: 跳转已存在则跳过 (cron 每5分钟重复触发超限时不再堆积重复规则)
        for _CHAIN in INPUT OUTPUT FORWARD; do
            "\$FW" -C "\$_CHAIN" -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null \
                || "\$FW" -I "\$_CHAIN" 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
        done
    }
    [ "\$HAS_V4" = "1" ] && command -v iptables  >/dev/null 2>&1 && apply_fw iptables  icmp
    [ "\$HAS_V6" = "1" ] && command -v ip6tables >/dev/null 2>&1 && apply_fw ip6tables ipv6-icmp

    log "网络已限制 (TRAFFIC_BLOCKED 双向封锁，仅保留 SSH / DNS / lo)。"
else
    echo "状态: [正常] 流量未超限。"

    # 流量回落则状态归位 normal (超限通知标记不清零：同月再超限只封网不重发；
    # 恢复通知由 reset 触发，此处不发)
    if [ "\$STATE" = "blocked" ]; then
        STATE=normal
        save_state
        log "检测到流量回落，状态恢复正常 (超限通知标记保留，同月再超限不重发)。"
    else
        save_state
        log "流量正常。"
    fi
fi
fi
EOF

# 5. 生成重置脚本 ($SCRIPT_DIR/reset_network.sh)
#    配置同样从 CONF_FILE 读取。
echo "--> 生成重置脚本 $SCRIPT_DIR/reset_network.sh..."
cat > "$SCRIPT_DIR/reset_network.sh" <<EOF
#!/bin/bash

CONF_FILE="$CONF_FILE"
NETMON_KEY="$NETMON_KEY"
SCRIPT_DIR="$SCRIPT_DIR"
RESET_LOG="/var/log/network_reset.log"
LOG_FILE="/var/log/traffic_monitor.log"
STATE_FILE="/var/lib/traffic_monitor/state"
# TG 发送历史 (与 check 共用同一文件：一行一月 UTC 时间戳，OVER 超限 / RESTORE 恢复)；
# 格式: YYYY-MM OVER=<UTC|-> RESTORE=<UTC|->；每月各最多 1 条的判定依据；
# reset 只记恢复、保留超限；只保留最近 12 个月
NOTIFY_FILE="/var/lib/traffic_monitor/notify"
# 上个月流量月度档案 (长期留存): 每次月度重置时把上月最终上下行追加一行, 一行一月
ARCHIVE_FILE="/var/lib/traffic_monitor/archive"

# 读取运行时配置
if [ -r "\$CONF_FILE" ]; then
    . "\$CONF_FILE"
else
    echo "错误：缺少配置文件 \$CONF_FILE" >&2
    exit 1
fi

# 当月超限通知是否已发送 (兼容第一代 OVER_MONTH= 变量行)
notify_over_sent() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    [ -f "\$NOTIFY_FILE" ] || return 1
    grep -q "^OVER_MONTH=\$CUR_MONTH\$" "\$NOTIFY_FILE" 2>/dev/null && return 0
    _line="\$(grep -E "^\$CUR_MONTH[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
    [ -n "\$_line" ] || return 1
    _v=""
    for _f in \$_line; do
        case "\$_f" in
            OVER=*) _v="\${_f#OVER=}"; break ;;
        esac
    done
    [ -n "\$_v" ] && [ "\$_v" != "-" ]
}

# 当月恢复通知是否已发送 (兼容第一代 RESTORE_MONTH= 变量行)
notify_restore_sent() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    [ -f "\$NOTIFY_FILE" ] || return 1
    grep -q "^RESTORE_MONTH=\$CUR_MONTH\$" "\$NOTIFY_FILE" 2>/dev/null && return 0
    _line="\$(grep -E "^\$CUR_MONTH[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
    [ -n "\$_line" ] || return 1
    _v=""
    for _f in \$_line; do
        case "\$_f" in
            RESTORE=*) _v="\${_f#RESTORE=}"; break ;;
        esac
    done
    [ -n "\$_v" ] && [ "\$_v" != "-" ]
}

# 记一条发送历史 (UTC 时间戳)：\$1=OVER|RESTORE；输出本次时间戳；只保留最近 12 个月
notify_mark() {
    [ -n "\$CUR_MONTH" ] || CUR_MONTH=\$(date '+%Y-%m')
    _type="\$1"
    _ts="\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    _m="\$CUR_MONTH"
    mkdir -p "\$(dirname "\$NOTIFY_FILE")"
    _tmp="\${NOTIFY_FILE}.tmp"
    _old_over="-"; _old_restore="-"
    if [ -f "\$NOTIFY_FILE" ]; then
        _oldline="\$(grep -E "^\${_m}[[:space:]]" "\$NOTIFY_FILE" 2>/dev/null | tail -n1)"
        if [ -n "\$_oldline" ]; then
            for _f in \$_oldline; do
                case "\$_f" in
                    OVER=*) _old_over="\${_f#OVER=}" ;;
                    RESTORE=*) _old_restore="\${_f#RESTORE=}" ;;
                esac
            done
            [ -n "\$_old_over" ] || _old_over="-"
            [ -n "\$_old_restore" ] || _old_restore="-"
        fi
        grep -Ev '^(OVER_MONTH|RESTORE_MONTH|OVER_TIME|RESTORE_TIME)=' "\$NOTIFY_FILE" 2>/dev/null | grep -Ev "^\${_m}[[:space:]]" > "\$_tmp" 2>/dev/null || : > "\$_tmp"
    else
        : > "\$_tmp"
    fi
    case "\$_type" in
        OVER) _old_over="\$_ts" ;;
        RESTORE) _old_restore="\$_ts" ;;
    esac
    printf '%s OVER=%s RESTORE=%s\n' "\$_m" "\${_old_over:--}" "\${_old_restore:--}" >> "\$_tmp"
    sort -k1,1 "\$_tmp" 2>/dev/null | tail -n 12 > "\$NOTIFY_FILE" 2>/dev/null || tail -n 12 "\$_tmp" > "\$NOTIFY_FILE"
    rm -f "\$_tmp"
    printf '%s' "\$_ts"
}

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
# LIMIT 无默认值：空/0/-1 = 无限制；reset 侧不做封网比较，只原样归档/展示
LIMIT="\${LIMIT:-}"
DNS_SERVERS="\${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
# 地址族标记：缺失时按命令可用性兜底
HAS_V4="\${HAS_V4:-1}"
HAS_V6="\${HAS_V6:-1}"
command -v iptables  >/dev/null 2>&1 || HAS_V4=0
command -v ip6tables >/dev/null 2>&1 || HAS_V6=0
# 日志保留天数：重置时只保留最近 N 天，删除更早的行（0/-1=保留全部）
LOG_RETENTION_DAYS="\${LOG_RETENTION_DAYS:-7}"
case "\$LOG_RETENTION_DAYS" in
    ''|*[!0-9-]*|-) LOG_RETENTION_DAYS=7 ;;
esac

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
    local geo ip city cc loc masked ipv4 ipv6
    geo=""
    # 双栈分别取：v4 走 ip-api（带定位），v6 走 ipwho.is/ipify（仅地址）；
    # 单栈只取对应族；本机IP行按族拼接（双栈显示两个，单栈显示一个）
    ipv4=""; ipv6=""
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
    # 主 IP 归族：v4 格式进 ipv4，v6（含 ::）进 ipv6
    case "\$ip" in
        "") : ;;
        *:* ) ipv6="\$ip" ;;
        *) ipv4="\$ip" ;;
    esac
    # 定位互补：主查询无定位（v4 被墙/CF 盖住/unknown）且双栈时，用另一族补一次定位；
    # 通知在封网前/解封后发送，此时外网可用，多一次请求可接受
    if [ -z "\$city$cc" ] || [ "\$cc" = "unknown" ]; then
        _geo2=""
        case "\$ip" in
            *:* )
                [ "\$HAS_V4" = "1" ] && _geo2=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null) ;;
            *)
                [ "\$HAS_V6" = "1" ] && _geo2=\$(curl -6 -s --max-time 5 "https://ipwho.is/" 2>/dev/null) ;;
        esac
        if [ -n "\$_geo2" ]; then
            _c2=\$(echo "\$_geo2" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
            _cc2=\$(echo "\$_geo2" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
            [ -z "\$_cc2" ] && _cc2=\$(echo "\$_geo2" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')
            [ -n "\$_c2" ] && city="\$_c2"
            [ -n "\$_cc2" ] && cc="\$_cc2"
        fi
    fi
    # 双栈补取另一族地址：v4 已有则补 v6（ipify v6），v6 已有则补 v4（ipify v4）
    if [ "\$HAS_V6" = "1" ] && [ -z "\$ipv6" ]; then
        ipv6=\$(curl -6 -s --max-time 5 "https://api64.ipify.org" 2>/dev/null)
    fi
    if [ "\$HAS_V4" = "1" ] && [ -z "\$ipv4" ]; then
        ipv4=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi
    # 外部查询全部失败时 (如封网断外网) 回退用本机网卡地址, 保证 IP 不至于空白
    if [ -z "\$ipv4" ] && [ "\$HAS_V4" = "1" ]; then
        ipv4=\$(ip -4 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1)
    fi
    if [ -z "\$ipv6" ] && [ "\$HAS_V6" = "1" ]; then
        ipv6=\$(ip -6 -o addr show 2>/dev/null | awk '\$2=="'"\$INTERFACE"'" {print \$4; exit}' | cut -d/ -f1 | cut -d% -f1)
    fi
    # 拼接展示：双栈 "v4 / v6"，单栈单个；masked 与 ip 同值（当前不打码）
    if [ -n "\$ipv4" ] && [ -n "\$ipv6" ]; then
        masked="\$ipv4 / \$ipv6"
        ip="\$ipv4 / \$ipv6"
    elif [ -n "\$ipv4" ]; then
        masked="\$ipv4"
        ip="\$ipv4"
    else
        masked="\$ipv6"
        ip="\$ipv6"
    fi
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

# 采样当月上下行累计 (返回 "上行(TX) 下行(RX)" 两值)
# 数据来源: 独立统计脚本 netstat.sh (与 check 共用同一份, nezha 式 /proc/net/dev + 月度增量)
# 注意: 必须在 reset 前调用一次 (采样当月最终值), reset 会清零计数。
NETSTAT_BIN="\$SCRIPT_DIR/netstat.sh"
read_traffic_last() {
    local out
    out=\$("$NETSTAT_BIN" 2>/dev/null)
    LAST_MONTH_TX=\${out%% *}
    LAST_MONTH_RX=\${out##* }
    if ! [[ "\$LAST_MONTH_TX" =~ ^[0-9]+$ ]]; then LAST_MONTH_TX=0; fi
    if ! [[ "\$LAST_MONTH_RX" =~ ^[0-9]+$ ]]; then LAST_MONTH_RX=0; fi
}

# 小数补前导 0: bc 输出如 .65 时补成 0.65 (终端/TG/日志统一正常显示)
fmt_fix() {
    case "\$1" in
        .*) echo "0\$1" ;;
        *)  echo "\$1" ;;
    esac
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
        echo "\$(fmt_fix "\$(echo "scale=2; \$bytes / 1048576" | bc)")MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        echo "\$(fmt_fix "\${b}")GB"
    else
        echo "\$(fmt_fix "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)")TB"
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

# 1. 清理旧日志：只保留最近 LOG_RETENTION_DAYS 天的日志行（写入由 check_traffic.sh 的 log() 负责）
if [ -f "\$LOG_FILE" ]; then
    if [ "\$LOG_RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
        # 行首为 ISO 日期 (YYYY-MM-DD)，按字符串比较截断；GNU/BusyBox date 均支持 -d
        CUTOFF=\$(date -d "\${LOG_RETENTION_DAYS} days ago" '+%Y-%m-%d' 2>/dev/null)
        [ -z "\$CUTOFF" ] && CUTOFF=\$(date '+%Y-%m-%d')
        awk -v c="\$CUTOFF" 'substr(\$0,1,10) >= c' "\$LOG_FILE" > "\$LOG_FILE.tmp" 2>/dev/null && mv "\$LOG_FILE.tmp" "\$LOG_FILE"
        log "流量监控日志已清理，保留最近 \${LOG_RETENTION_DAYS} 天 (截断点 \$CUTOFF)：\$LOG_FILE"
    else
        log "日志保留策略为保留全部 (LOG_RETENTION_DAYS=\$LOG_RETENTION_DAYS)，不清理 \$LOG_FILE。"
    fi
else
    log "流量监控日志不存在，无需清理。"
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
#    在重置前先采样"上个月"最终上下行流量 (reset 后计数清零，用于恢复通知展示)
read_traffic_last
# 3.1 归档"上个月"最终上下行到月度档案 (长期留存, 一行一月, 同一月只追加一次)
#    月份取 netstat.sh 状态文件中的 MONTH (此时尚未 reset, 仍是上月标识, 与本次归档的数值同月)
ARCH_MONTH="\$(sed -n 's/^MONTH=//p' /var/lib/traffic_monitor/netcount 2>/dev/null | tail -n1)"
if [ -n "\$ARCH_MONTH" ] && ! grep -q "^[[:space:]]*\$ARCH_MONTH[[:space:]]" "\$ARCHIVE_FILE" 2>/dev/null; then
    mkdir -p "\$(dirname "\$ARCHIVE_FILE")"
    # 字段: 月份 TX=上月上流 RX=上月下流 mode=计费口径 blocked=上月是否触发封网(blocked=触发 normal=未触发)
    printf '%s TX=%s RX=%s mode=%s blocked=%s\n' "\$ARCH_MONTH" "\$LAST_MONTH_TX" "\$LAST_MONTH_RX" "\$STAT_MODE" "\$STATE" >> "\$ARCHIVE_FILE"
    log "已归档上个月流量到月度档案: \$ARCH_MONTH 上行 \$(format_traffic "\$LAST_MONTH_TX") / 下行 \$(format_traffic "\$LAST_MONTH_RX") (口径 \$STAT_MODE, 封网 \$STATE)"

    # --- 3.1.2 总计流量 (从开始到现在 各类流量总计, 长期累计一笔, 卸载不清, 永不裁剪) ---
    #    字段: 月份 TX=上行总计 RX=下行总计 mode=计费口径
    GRAND_TOTAL_FILE="/var/lib/traffic_monitor/grand_total"
    if [ -n "\$ARCH_MONTH" ] && ! grep -q "^[[:space:]]*\$ARCH_MONTH[[:space:]]" "\$GRAND_TOTAL_FILE" 2>/dev/null; then
        mkdir -p "\$(dirname "\$GRAND_TOTAL_FILE")"
        OLD_GD_TX="\$(sed -n 's/^TOTAL_TX=//p' "\$GRAND_TOTAL_FILE" 2>/dev/null | tail -n1)"
        OLD_GD_RX="\$(sed -n 's/^TOTAL_RX=//p' "\$GRAND_TOTAL_FILE" 2>/dev/null | tail -n1)"
        OLD_GD_TX="\${OLD_GD_TX:-0}"; OLD_GD_RX="\${OLD_GD_RX:-0}"
        NEW_GD_TX=\$((OLD_GD_TX + LAST_MONTH_TX))
        NEW_GD_RX=\$((OLD_GD_RX + LAST_MONTH_RX))
        # 月度快照也归档 netcount (本月数据按年月留存, 保留近12月)
        NETCOUNT_SNAP="/var/lib/traffic_monitor/netcount_\$ARCH_MONTH"
        if [ -f /var/lib/traffic_monitor/netcount ] && [ ! -f "\$NETCOUNT_SNAP" ]; then
            cp -p /var/lib/traffic_monitor/netcount "\$NETCOUNT_SNAP"
            log "已归档本月流量快照: \$ARCH_MONTH"
        fi
        # 保留近12月: 只留最近12个 netcount_* 月度快照 (先裁再加新, 保证同月只留一份; archive/总计 长期留存不在此列)
        if command -v ls >/dev/null 2>&1; then
            ls -1 /var/lib/traffic_monitor/netcount_????-?? 2>/dev/null | sort | head -n -12 | while read -r _old; do
                [ -n "$_old" ] && rm -f "$_old" 2>/dev/null || true
            done
        fi
        printf 'TOTAL_TX=%s TOTAL_RX=%s MONTH=%s\n' "\$NEW_GD_TX" "\$NEW_GD_RX" "\$ARCH_MONTH" > "\$GRAND_TOTAL_FILE"
        log "总计流量已更新: 从开始到现在 上行 \$(format_traffic "\$NEW_GD_TX") / 下行 \$(format_traffic "\$NEW_GD_RX") (截至 \$ARCH_MONTH)"
    else
        log "总计流量本月已计入或月份无效，跳过。"
    fi
else
    log "上月流量档案已存在或月份无效，跳过归档。"
fi
if [ "\$LAST_MONTH_TX" -gt 0 ] 2>/dev/null || [ "\$LAST_MONTH_RX" -gt 0 ] 2>/dev/null; then
    log "上个月流量: 上行 \$(format_traffic "\$LAST_MONTH_TX") / 下行 \$(format_traffic "\$LAST_MONTH_RX")"
fi
"$NETSTAT_BIN" --reset >/dev/null 2>&1 || true
log "流量统计已重置 (netstat.sh 当月累计清零)。"

# 4. 网络恢复后发送 TG 通知 (仅当 TG 启用且上月处于断网状态时发送一次)
#    在防火墙已全部放开之后发送 (此时网络可用，能获取 IP)
sleep 1

# 判定是否需要发恢复通知：上月确实超限封网过 + TG 启用 + 当月未发送过恢复通知
# (以 notify 历史为准；上月月份与恢复月份天然不同月，无需额外比对)
NEED_RESTORE=0
if [ "\$STATE" = "blocked" ] && [ "\$TG_ON" = "1" ] && ! notify_restore_sent; then
    NEED_RESTORE=1
fi

# 更新状态文件: 恢复 -> normal，记录恢复时间，进入新月份周期
# 同步落盘快照字段（口径/上限/重置后清零的当月上下行），保证 state 自包含可查
STATE=normal
MONTH="\$CUR_MONTH"
RESTORED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
USED_STAT_MODE="\$STAT_MODE"
USED_LIMIT="\$LIMIT"
USED_TX=0
USED_RX=0
USED_BAL=0
mkdir -p "\$(dirname "\$STATE_FILE")"
cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME="\$BLOCKED_TIME"
BLOCKED_TX="\$BLOCKED_TX"
RESTORED_TIME="\$RESTORED_TIME"
USED_STAT_MODE=\$USED_STAT_MODE
USED_LIMIT=\$USED_LIMIT
USED_TX=\$USED_TX
USED_RX=\$USED_RX
USED_BAL=\$USED_BAL
STATE_EOF

if [ "\$NEED_RESTORE" -eq 1 ]; then
IFS='|' read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
    RUN_TIME=\$(TZ='UTC-8' date '+%Y-%m-%d %H:%M:%S')   # TG 展示用北京时间 (busybox TZ=UTC-8 = UTC+8)
    MONTH_TX=0
    MONTH_RX=0
    # 上个月(重置前周期)最终流量: 步骤3已采样 (LAST_MONTH_TX/RX)
    LAST_MONTH_OK=0
    if [ "\$LAST_MONTH_TX" -gt 0 ] 2>/dev/null || [ "\$LAST_MONTH_RX" -gt 0 ] 2>/dev/null; then
        LAST_MONTH_OK=1
    fi
    # CPU 行 (仅 oracle 显示)
    CPU_LINE=""
    if is_oracle_platform; then
        CPU_LINE="
🌐 CPU: \$(get_cpu_type)"
    fi

    # 本月口径中文名 (与超限通知一致: sum-总和 / out-出站 / in-入站 / max-取大 / min-取小)
    case "\$STAT_MODE" in
        out) STAT_LABEL="out-出站" ;;
        in)  STAT_LABEL="in-入站" ;;
        max) STAT_LABEL="max-取大" ;;
        min) STAT_LABEL="min-取小" ;;
        *)   STAT_LABEL="sum-总和" ;;
    esac
    # 本月已用流量 (重置已清零, 恒为 0; 仍按口径算, 与超限通知同口径逻辑)
    case "\$STAT_MODE" in
        in)  BAL_CUR="\$MONTH_RX" ;;
        out) BAL_CUR="\$MONTH_TX" ;;
        max) [ "\$MONTH_TX" -ge "\$MONTH_RX" ] 2>/dev/null && BAL_CUR="\$MONTH_TX" || BAL_CUR="\$MONTH_RX" ;;
        min) [ "\$MONTH_TX" -le "\$MONTH_RX" ] 2>/dev/null && BAL_CUR="\$MONTH_TX" || BAL_CUR="\$MONTH_RX" ;;
        *)   BAL_CUR=\$(( MONTH_TX + MONTH_RX )) ;;
    esac
    USED_FMT_CUR="\$(format_traffic "\$BAL_CUR")"
    USED_UNIT_CUR="\$(printf '%s' "\$USED_FMT_CUR" | grep -oE 'MB|GB|TB' | tail -n1)"
    # 本月上限换算: 与超限通知同逻辑, 按本月已用单位换算 (本月恒 0MB -> 上限换算成 MB, 如 上限: 10 GB (10240.00MB))
    LIMIT_BYTES_RST=\$(echo "scale=0; \$LIMIT * 1073741824 / 1" | bc 2>/dev/null)
    LIMIT_DISPLAY_CUR="\$LIMIT GB"
    if [ -n "\$USED_UNIT_CUR" ] && [ "\$USED_UNIT_CUR" != "GB" ]; then
        case "\$USED_UNIT_CUR" in
            MB) LIMIT_DIV_CUR=1048576 ;;
            TB) LIMIT_DIV_CUR=1099511627776 ;;
            *)  LIMIT_DIV_CUR=1073741824 ;;
        esac
        case "\$LIMIT_BYTES_RST" in ''|*[!0-9]*) : ;; *)
            LIMIT_CONV_CUR="\$(fmt_fix "\$(echo "scale=2; \$LIMIT_BYTES_RST / \$LIMIT_DIV_CUR" | bc)") \$USED_UNIT_CUR"
            LIMIT_DISPLAY_CUR="\$LIMIT GB (\$LIMIT_CONV_CUR)" ;;
        esac
    fi
    # 上月口径: 优先用 state 落盘的 USED_STAT_MODE (封网当时的口径), 缺失回退当前 STAT_MODE
    LAST_STAT_MODE="\${USED_STAT_MODE:-\$STAT_MODE}"
    case "\$LAST_STAT_MODE" in out|in|max|min|sum) : ;; *) LAST_STAT_MODE="\$STAT_MODE" ;; esac
    case "\$LAST_STAT_MODE" in
        out) LAST_STAT_LABEL="out-出站" ;;
        in)  LAST_STAT_LABEL="in-入站" ;;
        max) LAST_STAT_LABEL="max-取大" ;;
        min) LAST_STAT_LABEL="min-取小" ;;
        *)   LAST_STAT_LABEL="sum-总和" ;;
    esac
    # 上月已用流量 (按上月口径算, 与超限通知同口径逻辑)
    case "\$LAST_STAT_MODE" in
        in)  LAST_BAL="\$LAST_MONTH_RX" ;;
        out) LAST_BAL="\$LAST_MONTH_TX" ;;
        max) [ "\$LAST_MONTH_TX" -ge "\$LAST_MONTH_RX" ] 2>/dev/null && LAST_BAL="\$LAST_MONTH_TX" || LAST_BAL="\$LAST_MONTH_RX" ;;
        min) [ "\$LAST_MONTH_TX" -le "\$LAST_MONTH_RX" ] 2>/dev/null && LAST_BAL="\$LAST_MONTH_TX" || LAST_BAL="\$LAST_MONTH_RX" ;;
        *)   LAST_BAL=\$(( LAST_MONTH_TX + LAST_MONTH_RX )) ;;
    esac
    LAST_USED_FMT="\$(format_traffic "\$LAST_BAL")"
    LAST_USED_UNIT="\$(printf '%s' "\$LAST_USED_FMT" | grep -oE 'MB|GB|TB' | tail -n1)"
    # 上月上限换算: 与超限通知同逻辑, 按上月已用单位换算
    LIMIT_DISPLAY_LAST="\$LIMIT GB"
    if [ -n "\$LAST_USED_UNIT" ] && [ "\$LAST_USED_UNIT" != "GB" ]; then
        case "\$LAST_USED_UNIT" in
            MB) LIMIT_DIV_LAST=1048576 ;;
            TB) LIMIT_DIV_LAST=1099511627776 ;;
            *)  LIMIT_DIV_LAST=1073741824 ;;
        esac
        case "\$LIMIT_BYTES_RST" in ''|*[!0-9]*) : ;; *)
            LIMIT_CONV_LAST="\$(fmt_fix "\$(echo "scale=2; \$LIMIT_BYTES_RST / \$LIMIT_DIV_LAST" | bc)") \$LAST_USED_UNIT"
            LIMIT_DISPLAY_LAST="\$LIMIT GB (\$LIMIT_CONV_LAST)" ;;
        esac
    fi
    LAST_MONTH_LINE=""
    if [ "\$LAST_MONTH_OK" = "1" ]; then
        LAST_MONTH_LINE="
📊 上月计费口径: \$LAST_STAT_LABEL / 上限: \$LIMIT_DISPLAY_LAST
🌐 上月已用流量: \$LAST_USED_FMT / (上行 \$(format_traffic "\$LAST_MONTH_TX") / 下行 \$(format_traffic "\$LAST_MONTH_RX")) (重置前耗尽)"
    fi

    TG_MSG="🎮 \$PLATFORM 流量报告（网络恢复通知）

📍 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$RUN_TIME
📚 网络状态: 超限封网 ---> 已恢复
📊 计费口径: \$STAT_LABEL / 上限: \$LIMIT_DISPLAY_CUR
🌐 已用流量: \$USED_FMT_CUR / (上行 \$(format_traffic "\$MONTH_TX") / 下行 \$(format_traffic "\$MONTH_RX"))\${LAST_MONTH_LINE}\${CPU_LINE}"

    tg_send "\$TG_MSG"
    RESTORE_TS="\$(notify_mark RESTORE)"
    log "已发送网络恢复 TG 通知 (\$RESTORE_TS)。"
else
    if [ "\$STATE" != "blocked" ]; then
        log "上月网络正常，无需发送恢复通知。"
    elif [ "\$TG_ON" != "1" ]; then
        log "TG 未启用，跳过恢复通知。"
    else
        log "本月已发送恢复通知，跳过 (见 \$NOTIFY_FILE)。"
    fi
fi
EOF

# 6. 赋予执行权限 + 落盘部署器 + 创建快捷指令（复用 quick_install，幂等）
chmod +x "$SCRIPT_DIR/check_traffic.sh"
chmod +x "$SCRIPT_DIR/reset_network.sh"
quick_install || echo "--> 警告：快捷指令创建失败，不影响部署本身。" >&2

# 7. 设置定时任务
echo "--> 更新 Crontab 定时任务..."
crontab -l > /tmp/cron_bk 2>/dev/null

# 清理旧任务，防止重复（含旧版 /root 直放路径的残留）
sed -i '/check_traffic.sh/d' /tmp/cron_bk
sed -i '/reset_network.sh/d' /tmp/cron_bk

# 添加新任务
# 每5分钟检查一次流量
echo "*/5 * * * * $SCRIPT_DIR/check_traffic.sh" >> /tmp/cron_bk
# 每月1号 00:00 重置网络和日志
echo "0 0 1 * * $SCRIPT_DIR/reset_network.sh" >> /tmp/cron_bk

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
echo "  bash $SCRIPT_DIR/check_traffic.sh"
echo ""
echo "运行时脚本目录   : $SCRIPT_DIR (check/reset/netstat 统一收拢于此)"
echo "运行时配置文件   : $CONF_FILE (0600，请勿手改；改动请用子命令)"
echo "TG 密钥文件      : $NETMON_KEY (0600，丢失后凭据不可恢复)"
echo ""
echo "后续配置修改/查看命令（快捷指令 ${TFC_NAME:-tfc} 与 bash $0 等价）："
echo "  ${TFC_NAME:-tfc} edit       # 交互式菜单：修改平台/上限/端口/DNS/网卡/TG"
echo "  ${TFC_NAME:-tfc} config     # 查看当前配置 (TG 凭据掩码显示)"
echo "  ${TFC_NAME:-tfc} check      # 查看流量"
echo "  ${TFC_NAME:-tfc} restore    # 恢复网络"
echo "  bash $0 set-tg     # 换 TG: TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash $0 set-tg"
echo "  bash $0 clear-tg   # 停用并清除 TG 凭据"
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
}

# ---------------- 入口分派（main） ----------------
main() {
    case "${1:-}" in
        "" | menu)
            main_menu
            ;;
        req | install)
            do_install
            # 覆盖安装后停住，按任意键进入管理菜单 (非交互 stdin 下 read 直接 EOF 进菜单后退出，不阻塞自动化)
            printf "\033[32m安装已结束，按任意键进入菜单...\033[0m"
            read -r -n1 _k < /dev/tty 2>/dev/null || read -r _k 2>/dev/null || true
            echo ""
            main_menu
            ;;
        set-tg)
            tg_set
            ;;
        clear-tg)
            tg_clear
            ;;
        config)
            config_show
            ;;
        edit)
            config_edit
            ;;
        check | status-t)
            menu_check
            ;;
        restore | unblock)
            menu_restore
            ;;
        update | upgrade)
            menu_update
            ;;
        reset-notify)
            tg_notify_reset
            ;;
        del | un)
            uninstall
            ;;
        -h | --help | help)
            print_usage
            ;;
        *)
            echo "未知命令：${1}" >&2
            print_usage
            exit 1
            ;;
    esac
}

# 测试钩子：NETMON_TEST_MODE=1 时只 source 函数定义（供 tests/smoke-netmon.sh），不进入 main
if [ "${NETMON_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi