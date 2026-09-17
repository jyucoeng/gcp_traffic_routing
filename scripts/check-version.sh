#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  XX  %s\n' "$1" >&2; }

# ---------- 版本一致性 ----------
VERSION="$(tr -d '\r\n' <"${ROOT_DIR}/VERSION")"
S_VERSION="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "${ROOT_DIR}/cdn.sh")"
I_VERSION="$(sed -n 's/^PROJECT_VERSION="\([^"]*\)"/\1/p' "${ROOT_DIR}/install.sh")"
I_PACKAGE="$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' "${ROOT_DIR}/install.sh")"
I_SHA="$(sed -n 's/^PACKAGE_SHA256="\([^"]*\)"/\1/p' "${ROOT_DIR}/install.sh")"

if [ -n "${S_VERSION}" ] && [ -n "${VERSION}" ] && [ "${VERSION}" = "v${S_VERSION}" ]; then
  ok "VERSION=${VERSION} 与 cdn.sh SCRIPT_VERSION=${S_VERSION} 一致"
else
  bad "版本不一致：VERSION=${VERSION} / cdn.sh SCRIPT_VERSION=${S_VERSION}"
fi

if [ -n "${I_VERSION}" ] && [ "${I_VERSION}" = "${VERSION}" ]; then
  ok "install.sh PROJECT_VERSION=${I_VERSION} 与 VERSION 一致"
else
  bad "install.sh PROJECT_VERSION=${I_VERSION} 与 VERSION=${VERSION} 不一致"
fi

if [ -n "${I_PACKAGE}" ] && [ "${I_PACKAGE}" = "gcp_traffic_routing-${VERSION}.tar.gz" ]; then
  ok "install.sh PACKAGE_NAME=${I_PACKAGE} 与 VERSION 一致"
else
  bad "install.sh PACKAGE_NAME=${I_PACKAGE} 应为 gcp_traffic_routing-${VERSION}.tar.gz"
fi

# ---------- 语法 ----------
if bash -n "${ROOT_DIR}/cdn.sh" && bash -n "${ROOT_DIR}/install.sh" \
  && bash -n "${ROOT_DIR}/scripts/build-release-bundle.sh" \
  && bash -n "${ROOT_DIR}/scripts/check-version.sh" \
  && bash -n "${ROOT_DIR}/tests/smoke.sh"; then
  ok "全部脚本 bash -n 通过"
else
  bad "存在脚本语法错误（bash -n）"
fi

# ---------- 构建 bundle 并与 install.sh 钉死哈希比对 ----------
if [ -n "${I_SHA}" ]; then
  bash "${ROOT_DIR}/scripts/build-release-bundle.sh" >/dev/null
  BUNDLE="${ROOT_DIR}/dist/${I_PACKAGE}"
  ACTUAL="$(sha256sum "${BUNDLE}" | awk '{print $1}')"
  if [ "${ACTUAL}" = "${I_SHA}" ]; then
    ok "bundle SHA256=${ACTUAL} 与 install.sh 钉死值一致"
  else
    bad "bundle SHA256=${ACTUAL} 与 install.sh 钉死值 ${I_SHA} 不一致"
  fi
  CHK="$(sed -n 's/^\([0-9a-f]\{64\}\)  '"${I_PACKAGE}"'$/\1/p' "${ROOT_DIR}/dist/checksums.txt" | head -n1)"
  if [ -n "${CHK}" ] && [ "${CHK}" = "${ACTUAL}" ]; then
    ok "dist/checksums.txt 与 bundle 一致"
  else
    bad "dist/checksums.txt 与 bundle 不一致（期望 ${ACTUAL}）"
  fi
  if tar -tzf "${BUNDLE}" | grep -qx "gcp_traffic_routing-${VERSION}/cdn.sh"; then
    ok "bundle 内含 cdn.sh"
  else
    bad "bundle 缺少 cdn.sh"
  fi
else
  bad "install.sh 缺少 PACKAGE_SHA256（尚未回填）"
fi

echo ""
echo "check-version 结果：${PASS} 通过 / ${FAIL} 失败"
[ "${FAIL}" = "0" ] || exit 1