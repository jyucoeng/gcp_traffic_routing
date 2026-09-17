#!/usr/bin/env bash
set -euo pipefail

TOTAL=0
PASS=0
FAIL=0

ok()   { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf '✅  %s\n' "$1"; }
bad()  { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf '❌  %s\n' "$1" >&2; }
assert_true()  { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
assert_false() { if eval "$1"; then bad "$2"; else ok "$2"; fi; }
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "${got}" = "${want}" ]; then
    ok "$name"
  else
    bad "$name (got=[${got}] want=[${want}])"
  fi
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 测试钩子：CDN_TEST_MODE=1 时本文件只 source cdn.sh 的函数定义，不进入 main
export CDN_TEST_MODE=1
export CDN_DIR="${TMP}/etc/cdn-manager"
export CDN_CONF="${TMP}/etc/dae/config.dae"

source "${SRC}/cdn.sh"

V="vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@1.2.3.4:443?encryption=none&security=tls#Name"
T="trojan://password123456@5.6.7.8:443#troj"
H2="hysteria2://h2pass@4.4.4.4:8443?sni=example.com&insecure=1#h2"
TU="tuic://uuid:tok@7.7.7.7:7777?sni=x#tuic"
ANYTLS="anytls://apass@8.8.8.8:443?insecure=1&sni=example.com#a"
VMESS="vmess://eyJ2IjoiMiJ9"
SS="ss://YWVzLTI1Ni1nY206Zm9v@9.9.9.9:8388#ss"
HTTP="http://blog.example.com/token"
VERYBAD="not-a-link"

# ---------- cdn_valid_link ----------
assert_true  "cdn_valid_link '${V}'"    "valid_link 接受 vless://"
assert_true  "cdn_valid_link '${T}'"    "valid_link 接受 trojan://"
assert_true  "cdn_valid_link '${H2}'"   "valid_link 接受 hysteria2://"
assert_true  "cdn_valid_link '${TU}'"   "valid_link 接受 tuic://"
assert_true  "cdn_valid_link '${ANYTLS}'" "valid_link 接受 anytls://"
assert_false "cdn_valid_link '${VMESS}'" "valid_link 拒绝 vmess://"
assert_false "cdn_valid_link '${SS}'"   "valid_link 拒绝 ss://"
assert_false "cdn_valid_link '${HTTP}'" "valid_link 拒绝 http://"
assert_false "cdn_valid_link '${VERYBAD}'" "valid_link 拒绝非链接"
assert_false "cdn_valid_link ''"        "valid_link 拒绝空串"

# ---------- cdn_mask_sub ----------
assert_eq "$(cdn_mask_sub 'https://sub.node.example.com/api/v3?t=abc')" \
  "https://sub.node.example.com/…" "mask_sub 裁剪 path/query 仅留 host"
assert_eq "$(cdn_mask_sub 'http://a.b.tk/t')" "http://a.b.tk/…" "mask_sub 支持 http"

# ---------- cdn_mask_link ----------
MASKED="$(cdn_mask_link "${V}")"
if printf '%s' "${MASKED}" | grep -Eq '^vless://#[0-9a-f]{6}@1\.2\.3\.4:443$'; then
  ok "mask_link 输出 摘要(6位)+host:port 且剥离 query"
else
  bad "mask_link 输出异常：${MASKED}"
fi
if [[ "${MASKED}" == *"aaaa-bbbb-cccc"* ]]; then
  bad "mask_link 泄露完整 UUID"
else
  ok "mask_link 不含完整 UUID"
fi
assert_eq "$(cdn_mask_link 'trojan://pw@6.6.6.6:443?x=1#t')" \
  "trojan://#$(sha256_str 'pw' | cut -c1-6)@6.6.6.6:443" "mask_link 兼容 trojan"
assert_eq "$(cdn_mask_link "${H2}")" \
  "hysteria2://#$(sha256_str 'h2pass' | cut -c1-6)@4.4.4.4:8443" "mask_link 兼容 hysteria2"
assert_eq "$(cdn_mask_link "${TU}")" \
  "tuic://#$(sha256_str 'uuid:tok' | cut -c1-6)@7.7.7.7:7777" "mask_link 兼容 tuic"
assert_eq "$(cdn_mask_link "${ANYTLS}")" \
  "anytls://#$(sha256_str 'apass' | cut -c1-6)@8.8.8.8:443" "mask_link 兼容 anytls"
if [[ "$(cdn_mask_link 'vless://h:80#x')" == "vless://h:80" ]]; then
  ok "mask_link 无 @ 凭据时原样输出 host:port"
else
  bad "mask_link 无凭据链接处理异常：$(cdn_mask_link 'vless://h:80#x')"
fi

# ---------- cdn_render_config：结构与策略 ----------
OUT="$(cdn_render_config)"
if [[ "${OUT}" == *"dip(geoip:cdnip) -> my_group"* ]]; then
  ok "render 包含 CDN 分流规则"
else
  bad "render 缺少 dip(geoip:cdnip) -> my_group"
fi
if [[ "${OUT}" == *"fallback: direct"* ]]; then
  ok "render 其余流量直连（fallback: direct）"
else
  bad "render 缺少 fallback: direct"
fi
if [[ "${OUT}" == *"policy: min"* ]]; then
  ok "render 默认策略 min"
else
  bad "render 缺少 policy: min"
fi
( cdn_policy=bogus; cdn_render_config ) >/dev/null 2>&1 && bad "非法策略未拒绝" || ok "非法策略被拒绝"
OUTFIX="$(cdn_policy='fixed(3)' cdn_render_config)"
if [[ "${OUTFIX}" == *"policy: fixed(3)"* ]]; then
  ok "render 支持 fixed(N) 合法策略"
else
  bad "render 未能输出 fixed(3)"
fi

# ---------- cdn_env_preload：node1/node2/sub1 预填（CDN_NO_APPLY 守卫内） ----------
node1="${V}" node2="${T}" sub1="https://sub.example.com/x" cdn_env_preload
if grep -qxF "${V}" "${CDN_NODES}"; then ok "preload 写入 node1"; else bad "preload 未写 node1"; fi
if grep -qxF "${T}" "${CDN_NODES}"; then ok "preload 写入 node2"; else bad "preload 未写 node2"; fi
if grep -qxF "https://sub.example.com/x" "${CDN_SUBS}"; then ok "preload 写入 sub1"; else bad "preload 未写 sub1"; fi

# ---------- render 携带节点/订阅数据 ----------
OUT3="$(cdn_render_config)"
if [[ "${OUT3}" == *"    '${V}'"* ]] && [[ "${OUT3}" == *"    '${T}'"* ]]; then
  ok "render 节点块包含全部节点"
else
  bad "render 节点块缺失节点"
fi
if [[ "${OUT3}" == *"sub_1: 'https://sub.example.com/x'"* ]]; then
  ok "render 订阅块自动编号 sub_1"
else
  bad "render 订阅块缺少 sub_1"
fi
printf 'mylabel:https://lab.example.com/t\n' >>"${CDN_SUBS}"
if [[ "$(cdn_render_config)" == *"mylabel: 'https://lab.example.com/t'"* ]]; then
  ok "render 订阅块支持自定义标签前缀"
else
  bad "render 订阅块自定义标签失败"
fi

# ---------- cdn_add：去重与非法输入 ----------
NODE_BEFORE="$(cdn_read_nodes | wc -l | tr -d ' ')"
CDN_NO_APPLY=1 cdn_add "${T}" "${VMESS}"
NODE_AFTER="$(cdn_read_nodes | wc -l | tr -d ' ')"
assert_eq "${NODE_AFTER}" "${NODE_BEFORE}" "cdn_add 去重已存在节点 + 忽略非法协议不写盘"

# ---------- is_num ----------
assert_true  "is_num '123'"    "is_num 接受纯数字"
assert_false "is_num '1a'"     "is_num 拒绝混入字母"
assert_false "is_num ''"       "is_num 拒绝空串"

# ---------- 交互菜单（stdin 管道模拟选择；非 TTY 下 bash read 抑制提示但正常读取） ----------
MENU_OUT="$(printf '4\n' | ( source "${SRC}/cdn.sh"; cdn_menu ) 2>&1 || true)"
if [[ "${MENU_OUT}" == *"设置分流节点"* ]] && [[ "${MENU_OUT}" == *"全量卸载"* ]]; then
  ok "菜单渲染（含 设置分流节点/全量卸载 选项）"
else
  bad "菜单渲染失败（缺少选项文本）"
fi
if printf '4\n' | ( source "${SRC}/cdn.sh"; cdn_menu ) >/dev/null 2>&1; then
  ok "菜单选择 4 退出返回 0"
else
  bad "菜单选择 4 未正常返回 0"
fi
MENU_BAD="$(printf 'x\n4\n' | ( source "${SRC}/cdn.sh"; cdn_menu ) 2>&1 || true)"
if [[ "${MENU_BAD}" == *"无效选择"* ]]; then
  ok "菜单非法选项被拒绝（x -> 无效选择）"
else
  bad "菜单非法选项未被拒绝"
fi
MENU_CANCEL="$(printf '3\nn\n4\n' | ( source "${SRC}/cdn.sh"; cdn_menu ) 2>&1 || true)"
if [[ "${MENU_CANCEL}" == *"已取消卸载"* ]]; then
  ok "菜单卸载需确认（n 取消）"
else
  bad "菜单卸载确认逻辑异常"
fi

# ---------- 补全：render 更多合法策略 ----------
for pol in random min_avg10 min_moving_avg; do
  OUTPOL="$(cdn_policy="${pol}" cdn_render_config)"
  if [[ "${OUTPOL}" == *"policy: ${pol}"* ]]; then
    ok "render 支持合法策略 ${pol}"
  else
    bad "render 未输出 policy: ${pol}"
  fi
done

# ---------- 补全：render 携带 anytls 节点 ----------
CDN_NO_APPLY=1 cdn_add "${ANYTLS}"
if [[ "$(cdn_render_config)" == *"    '${ANYTLS}'"* ]]; then
  ok "render 节点块包含 anytls 节点"
else
  bad "render 节点块缺失 anytls 节点"
fi

# ---------- 补全：cdn_add_sub 添加/去重/非法 ----------
NSUB_BEFORE="$(cdn_read_subs | wc -l | tr -d ' ')"
CDN_NO_APPLY=1 cdn_add_sub 'https://new.example.com/n?k=v'
NSUB_AFTER="$(cdn_read_subs | wc -l | tr -d ' ')"
assert_eq "$((NSUB_AFTER - NSUB_BEFORE))" "1" "add_sub 新增订阅计数"
if grep -qxF 'https://new.example.com/n?k=v' "${CDN_SUBS}"; then
  ok "add_sub 写入订阅"
else
  bad "add_sub 未写入订阅"
fi
CDN_NO_APPLY=1 cdn_add_sub 'https://new.example.com/n?k=v' >/dev/null 2>&1
assert_eq "$(cdn_read_subs | wc -l | tr -d ' ')" "${NSUB_AFTER}" "add_sub 重复订阅去重"
CDN_NO_APPLY=1 cdn_add_sub 'ftp://bad.example.com/x' >/dev/null 2>&1
assert_eq "$(cdn_read_subs | wc -l | tr -d ' ')" "${NSUB_AFTER}" "add_sub 拒绝非法 url 不写盘"
CDN_NO_APPLY=1 cdn_add_sub 'https://ok.example.com/x' 'bad label!' >/dev/null 2>&1
assert_eq "$(cdn_read_subs | wc -l | tr -d ' ')" "${NSUB_AFTER}" "add_sub 拒绝非法标签不写盘"
( cdn_add_sub ) >/dev/null 2>&1 && bad "add_sub 空参未拒绝" || ok "add_sub 空参被拒（无参数）"

# ---------- 补全：cdn_del / cdn_del_sub（stub 掉 cdn_apply 避免 require_root） ----------
cdn_apply() { :; }
NWANT="$(grep -vE '^[[:space:]]*$' "${CDN_NODES}" | wc -l | tr -d ' ')"
cdn_del '3' >/dev/null 2>&1
assert_eq "$(cdn_read_nodes | wc -l | tr -d ' ')" "$((NWANT - 1))" "del 按序号删除"
if ! grep -qxF "${ANYTLS}" "${CDN_NODES}"; then
  ok "del 删除的是 anytls 节点"
else
  bad "del 未删除 anytls 节点"
fi
NWANT="$(grep -vE '^[[:space:]]*$' "${CDN_NODES}" | wc -l | tr -d ' ')"
cdn_del '5.6.7.8' >/dev/null 2>&1
assert_eq "$(cdn_read_nodes | wc -l | tr -d ' ')" "$((NWANT - 1))" "del 按关键字删除"
if ! grep -qxF "${T}" "${CDN_NODES}"; then
  ok "del 关键字命中 trojan 节点"
else
  bad "del 关键字未删掉 trojan 节点"
fi
SWANT="$(grep -vE '^[[:space:]]*$' "${CDN_SUBS}" | wc -l | tr -d ' ')"
cdn_del_sub 'mylabel' >/dev/null 2>&1
assert_eq "$(cdn_read_subs | wc -l | tr -d ' ')" "$((SWANT - 1))" "del-sub 按标签关键字删除"
(cdn_del 'zzz-not-exist') >/dev/null 2>&1 && bad "del 未匹配时未失败" || ok "del 未匹配时拒绝"
(cdn_del_sub 'zzz-not-exist') >/dev/null 2>&1 && bad "del-sub 未匹配时未失败" || ok "del-sub 未匹配时拒绝"

# ---------- 补全：cdn_write_config（fake dae validate） ----------
cat >"${TMP}/fakedae-ok" <<'SH'
#!/bin/sh
[ "$1" = "validate" ] && exit 0
exit 1
SH
cat >"${TMP}/fakedae-bad" <<'SH'
#!/bin/sh
[ "$1" = "validate" ] && exit 1
exit 1
SH
chmod +x "${TMP}/fakedae-ok" "${TMP}/fakedae-bad"
rm -f "${CDN_CONF}"
DAE_BIN="${TMP}/fakedae-ok" cdn_write_config >/dev/null 2>&1
if [ -f "${CDN_CONF}" ] && [[ "$(cat "${CDN_CONF}")" == *"dip(geoip:cdnip) -> my_group"* ]]; then
  ok "write_config 校验通过后写盘"
else
  bad "write_config 校验通过后未写盘"
fi
CONF_BEFORE="$(cat "${CDN_CONF}")"
DAE_BIN="${TMP}/fakedae-bad" cdn_write_config >/dev/null 2>&1 && bad "write_config 校验失败未拦下" || ok "write_config 校验失败拒绝写盘"
assert_eq "$(cat "${CDN_CONF}")" "${CONF_BEFORE}" "write_config 校验失败不覆盖旧配置"
: >"${CDN_NODES}"
: >"${CDN_SUBS}"
rm -f "${CDN_CONF}"
DAE_BIN="${TMP}/fakedae-ok" cdn_write_config >/dev/null 2>&1
if [ -f "${CDN_CONF}" ]; then
  ok "write_config 空数据仍生成配置"
else
  bad "write_config 空数据未生成配置"
fi

echo ""
echo "smoke 结果：${PASS} 通过 / ${FAIL} 失败 / 共 ${TOTAL}"
[ "${FAIL}" = "0" ] || exit 1