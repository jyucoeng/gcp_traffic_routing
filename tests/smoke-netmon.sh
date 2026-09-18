#!/usr/bin/env bash
# netMonitor(traffic_ctrl.sh) 冒烟测试：纯函数与子命令逻辑，不触碰真实系统文件/防火墙。
set -euo pipefail

TOTAL=0
PASS=0
FAIL=0

ok()  { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf '✅  %s\n' "$1"; }
bad() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf '❌  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "${got}" = "${want}" ]; then
    ok "$name"
  else
    bad "$name (got=[${got}] want=[${want}])"
  fi
}

assert_true() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
assert_false() { if eval "$1"; then bad "$2"; else ok "$2"; fi; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 测试模式下 source：不执行部署，只加载函数与默认值解析
export NETMON_TEST_MODE=1
source "${SRC}/netMonitor/traffic_ctrl.sh"

# ---------- LIMIT 无默认值：未设置即为空，部署流程直接报错 ----------
assert_eq "${LIMIT:-}" "" "source 后默认 LIMIT 为空（无平台推断默认值）"
assert_false 'command -v resolve_limit >/dev/null' "resolve_limit 函数已删除"

# ---------- 纯函数：resolve_dns ----------
assert_eq "$(HAS_V4=0 HAS_V6=1 resolve_dns)" "2001:4860:4860::8888 2001:4860:4860::8844" "纯 IPv6 用 Google IPv6 DNS"
assert_eq "$(HAS_V4=1 HAS_V6=1 resolve_dns)" "8.8.8.8 8.8.4.4"                           "双栈用 IPv4 DNS"
assert_eq "$(HAS_V4=1 HAS_V6=0 resolve_dns)" "8.8.8.8 8.8.4.4"                           "纯 IPv4 用 IPv4 DNS"

# ---------- 纯函数：mask_mid ----------
assert_eq "$(mask_mid '1234567890')"       "123*****90"  "10 位掩码一半(前3后2遮5)"
assert_eq "$(mask_mid '987654321')"        "987****21"   "9 位掩码一半"
assert_eq "$(mask_mid '12345678')"         "12****78"    "8 位掩码一半"
assert_eq "$(mask_mid 'abcd')"             "****"        "4 位全隐藏"
assert_eq "$(mask_mid 'ab')"               "**"          "2 位全隐藏"
# 动态校验：长串掩码数量 = ceil(n/2)，裸露部分不含中间字符
LONG="tk123456789012345678901"
LMASK="$(mask_mid "$LONG")"
assert_eq "$(printf '%s' "$LMASK" | tr -cd '*' | wc -c | tr -d ' ')" "$(( ${#LONG} / 2 ))" "长串掩码数量=总数/2"
assert_eq "$(printf '%s' "$LMASK" | tr -cd ':' | wc -c | tr -d ' ')" "0" "掩码结果不含冒号"

# ---------- 加密/解密往返 ----------
KEY="${TMP}/netmon.key"
mkdir -p "${TMP}"
openssl rand -base64 32 > "${KEY}" 2>/dev/null || printf 'test-key-0000\n' > "${KEY}"
chmod 0600 "${KEY}"

TSECRET='tok:AbCdEf 1234-56-78 xyz'
NKEY="$KEY" bash -c '
  s="$1"
  enc="$(printf "%s" "$s" | openssl enc -aes-256-cbc -pbkdf2 -a -salt -pass file:"$NKEY" 2>/dev/null)"
  dec="$(printf "%s\n" "$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass file:"$NKEY" 2>/dev/null)"
  [ "$dec" = "$s" ] && echo OK || echo "FAIL[$dec]"
' _ "$TSECRET" > "${TMP}/roundtrip.out"
assert_eq "$(cat "${TMP}/roundtrip.out")" "OK" "AES-256 openssl 加密/解密往返"

# ---------- 子命令：set-tg / config / clear-tg（沙箱路径，不写 /etc） ----------
export CONF_FILE="${TMP}/netmonitor.conf"
export NETMON_KEY="${KEY}"
# 预置最小配置文件（模拟部署完成）
cat > "${CONF_FILE}" <<EOF
PLATFORM="gcp"
LIMIT=180
SSH_PORT=22
DNS_SERVERS="8.8.8.8 8.8.4.4"
INTERFACE="eth0"
TELEGRAM_BOT_TOKEN_ENC=""
TELEGRAM_CHAT_ID_ENC=""
EOF
chmod 0600 "${CONF_FILE}"

# require_root 在非 root 下会 exit——冒烟中绕过
require_root() { :; }

# set-tg：写入加密凭据
TELEGRAM_BOT_TOKEN='123456:ABCdefGHIJklmnOPqrstUVwxYZ0123456' TELEGRAM_CHAT_ID='987654321' tg_set >/dev/null 2>&1

# base64 密文可能跨行(openssl -a 64列)，用 tr 归并后检查
CONF_FLAT="$(tr -d '\n' < "${CONF_FILE}")"
if printf '%s' "${CONF_FLAT}" | grep -q 'TELEGRAM_BOT_TOKEN_ENC="U2FsdGVkX1'; then
  ok "set-tg 写入加密 BOT_TOKEN(AES-salt 标记)"
else
  bad "set-tg 未写入 BOT_TOKEN 密文"
fi
if printf '%s' "${CONF_FLAT}" | grep -q 'TELEGRAM_CHAT_ID_ENC="U2FsdGVkX1'; then
  ok "set-tg 写入加密 CHAT_ID"
else
  bad "set-tg 未写入 CHAT_ID 密文"
fi
if printf '%s' "${CONF_FLAT}" | grep -q '123456:ABCdef'; then
  bad "配置文件泄露明文 token"
else
  ok "配置文件不含明文 token"
fi

# config：掩码显示
CONF_OUT="$(config_show 2>&1)"
if printf '%s' "${CONF_OUT}" | grep -q '987\*\*\*\*21.*CHAT\|CHAT.*987\*\*\*\*21'; then
  ok "config 掩码显示 masked id(中间隐藏)"
else
  bad "config 未掩码显示 chat id：[${CONF_OUT}]"
fi
if printf '%s' "${CONF_OUT}" | grep -qE 'BOT TOKEN.*\*+'; then
  ok "config 掩码显示 masked token"
else
  bad "config 未掩码显示 token"
fi

# ---------- E2E：真实 TG 端到端（凭据走环境变量，不写死进仓库） ----------
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    # 用真实凭据重新 set-tg（覆盖单元段伪凭据），验证加密落盘
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}" tg_set >/dev/null 2>&1
    if grep -q '^TELEGRAM_BOT_TOKEN_ENC="U2FsdGVkX1' "${CONF_FILE}"; then
        ok "E2E set-tg 加密写入真实 token"
    else
        bad "E2E set-tg 未加密写入真实 token"
    fi
    # 运行时脚本侧解密逻辑往返一致 (base64 密文可能跨行，先整文件去换行再提取引号内内容)
    CONF_NL="$(tr -d '\n' < "${CONF_FILE}")"
    ENC_BOT="$(printf '%s' "${CONF_NL}" | sed -n 's/.*TELEGRAM_BOT_TOKEN_ENC="\([^"]*\)".*/\1/p')"
    ENC_CHAT="$(printf '%s' "${CONF_NL}" | sed -n 's/.*TELEGRAM_CHAT_ID_ENC="\([^"]*\)".*/\1/p')"
    DEC_BOT="$(dec_tg "${ENC_BOT}")"
    assert_eq "${DEC_BOT}" "${TELEGRAM_BOT_TOKEN}" "E2E 解密=原始 token(运行时逻辑)"
    assert_eq "$(dec_tg "${ENC_CHAT}")" "${TELEGRAM_CHAT_ID}" "E2E 解密=原始 chat_id"
    # 真实调用 Telegram API sendMessage（仿运行时脚本 tg_send）
    RESP="$(curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=netMonitor smoke-netmon E2E 测试消息" 2>/dev/null || true)"
    if printf '%s' "${RESP}" | grep -q '"ok":true' && printf '%s' "${RESP}" | grep -q '"result"'; then
        MID="$(printf '%s' "${RESP}" | sed -n 's/.*"message_id":\([0-9]*\).*/\1/p')"
        ok "E2E Telegram API 发送成功 (message_id=${MID})"
    else
        bad "E2E Telegram API 发送失败: ${RESP}"
    fi
    tg_clear >/dev/null 2>&1
else
    ok "E2E 真实发送跳过（无 TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID 环境变量时可选）"
fi

echo ""
echo "smoke-netmon 结果：${PASS} 通过 / ${FAIL} 失败 / 共 ${TOTAL}"
[ "${FAIL}" = "0" ] || exit 1