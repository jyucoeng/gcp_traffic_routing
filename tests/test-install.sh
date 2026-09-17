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

# 测试钩子：INSTALL_TEST_MODE=1 时本文件只 source install.sh 的函数定义，不进入 main
export INSTALL_TEST_MODE=1
source "${SRC}/install.sh"

# 常量自检
assert_eq "${REPO_OWNER}" "jyucoeng" "install.sh REPO_OWNER 正确"
assert_eq "${REPO_NAME}" "gcp_traffic_routing" "install.sh REPO_NAME 正确"
assert_eq "${PROJECT_VERSION}" "$(cat "${SRC}/VERSION")" "install.sh 版本与 VERSION 一致"
assert_eq "${PACKAGE_NAME}" "gcp_traffic_routing-${PROJECT_VERSION}.tar.gz" "install.sh 包名与版本一致"

# ---------- sha256_file ----------
printf 'hello sha256\n' >"${TMP}/a.txt"
EXPECTED="$(printf 'hello sha256\n' | shasum -a 256 | awk '{print $1}')"
assert_eq "$(sha256_file "${TMP}/a.txt")" "${EXPECTED}" "sha256_file 计算正确"

# ---------- verify_bundle：SHA 一致通过 / 不一致拒绝 ----------
mkdir -p "${TMP}/bundle/gcp_traffic_routing-v0.1.0"
cp "${SRC}/cdn.sh" "${TMP}/bundle/gcp_traffic_routing-v0.1.0/cdn.sh"
( cd "${TMP}/bundle" && tar -czf "${TMP}/pkg.tar.gz" "gcp_traffic_routing-v0.1.0" )
GOOD_SHA="$(sha256_file "${TMP}/pkg.tar.gz")"
PACKAGE_SHA256="${GOOD_SHA}" verify_bundle "${TMP}/pkg.tar.gz" && ok "verify_bundle 接受匹配 SHA" \
  || bad "verify_bundle 拒绝匹配 SHA"
PACKAGE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
( PACKAGE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"; \
  verify_bundle "${TMP}/pkg.tar.gz" ) >/dev/null 2>&1 \
  && bad "verify_bundle 放行错误 SHA" || ok "verify_bundle 拒绝错误 SHA"

# ---------- install_bundle：语法校验 + 安装到 CDN_BIN ----------
mkdir -p "${TMP}/bin" "${TMP}/bin2"
( PACKAGE_SHA256="${GOOD_SHA}"; CDN_BIN="${TMP}/bin/cdn"; install_bundle "${TMP}/pkg.tar.gz" ) >/dev/null 2>&1
if [ -x "${TMP}/bin/cdn" ]; then
  ok "install_bundle 安装 cdn.sh 到 CDN_BIN"
else
  bad "install_bundle 未安装 cdn.sh"
fi
# 非法脚本应被拒：造一个 cdn.sh 语法错误的包
mkdir -p "${TMP}/bad/gcp_traffic_routing-v0.1.0"
printf 'if [[ echo\n' >"${TMP}/bad/gcp_traffic_routing-v0.1.0/cdn.sh"
( cd "${TMP}/bad" && tar -czf "${TMP}/bad.tar.gz" "gcp_traffic_routing-v0.1.0" )
rm -f "${TMP}/bin2/cdn"
( CDN_BIN="${TMP}/bin2/cdn"; install_bundle "${TMP}/bad.tar.gz" ) >/dev/null 2>&1 \
  && bad "install_bundle 放行语法错误脚本" || ok "install_bundle 拒绝语法错误脚本"

# ---------- 非 root 拒绝（main 顶层守卫） ----------
if [ "${EUID:-$(id -u)}" = "0" ]; then
  ok "当前为 root，跳过非 root 守卫测试"
else
  ( main ) >/dev/null 2>&1 && bad "非 root 未拒绝 main" || ok "非 root 拒绝 main"
fi

echo ""
echo "install 测试结果：${PASS} 通过 / ${FAIL} 失败 / 共 ${TOTAL}"
[ "${FAIL}" = "0" ] || exit 1