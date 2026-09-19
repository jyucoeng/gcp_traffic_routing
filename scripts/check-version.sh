#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# 单事实源：source install.sh 读取全部项目常量（INSTALL_TEST_MODE=1 只取常量/函数，
# 不执行 main），Fork 后只需改写 install.sh 顶部 REPO_OWNER/REPO_NAME 即可全局生效。
INSTALL_TEST_MODE=1
source "${ROOT_DIR}/install.sh"
# 恢复本脚本自己的 shell 选项（install.sh source 时的 set 不影响调用方设置，此处显式声明）
set -eEuo pipefail

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '✅  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '❌  %s\n' "$1" >&2; }

# ---------- 版本一致性 ----------
VERSION="$(tr -d '\r\n' <"${ROOT_DIR}/VERSION")"
S_VERSION="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "${ROOT_DIR}/cdn.sh")"

if [ -n "${S_VERSION}" ] && [ -n "${VERSION}" ] && [ "${VERSION}" = "v${S_VERSION}" ]; then
  ok "VERSION=${VERSION} 与 cdn.sh SCRIPT_VERSION=${S_VERSION} 一致"
else
  bad "版本不一致：VERSION=${VERSION} / cdn.sh SCRIPT_VERSION=${S_VERSION}"
fi

if [ -n "${PROJECT_VERSION}" ] && [ "${PROJECT_VERSION}" = "${VERSION}" ]; then
  ok "install.sh PROJECT_VERSION=${PROJECT_VERSION} 与 VERSION 一致"
else
  bad "install.sh PROJECT_VERSION=${PROJECT_VERSION} 与 VERSION=${VERSION} 不一致"
fi

if [ -n "${PACKAGE_NAME}" ] && [ "${PACKAGE_NAME}" = "${REPO_NAME}-${VERSION}.tar.gz" ]; then
  ok "install.sh PACKAGE_NAME=${PACKAGE_NAME} 与 VERSION 一致"
else
  bad "install.sh PACKAGE_NAME=${PACKAGE_NAME} 应为 ${REPO_NAME}-${VERSION}.tar.gz"
fi

if [ -n "${REPO_OWNER}" ] && [ -n "${REPO_NAME}" ]; then
  ok "repo=${REPO_OWNER}/${REPO_NAME}（Fork 后仅需改 install.sh 顶部这两个常量）"
else
  bad "install.sh 缺少 REPO_OWNER/REPO_NAME"
fi

# ---------- 语法 ----------
if bash -n "${ROOT_DIR}/cdn.sh" && bash -n "${ROOT_DIR}/install.sh" \
  && bash -n "${ROOT_DIR}/scripts/build-release-bundle.sh" \
  && bash -n "${ROOT_DIR}/scripts/check-version.sh" \
  && bash -n "${ROOT_DIR}/tests/smoke.sh" \
  && bash -n "${ROOT_DIR}/tests/test-install.sh" \
  && bash -n "${ROOT_DIR}/netMonitor/traffic_ctrl.sh"; then
  ok "全部脚本 bash -n 通过"
else
  bad "存在脚本语法错误（bash -n）"
fi

if command -v sha256sum >/dev/null 2>&1; then
  SHA_BIN="sha256sum"
else
  SHA_BIN="shasum -a 256"
fi

# ---------- 构建 bundle 并与 install.sh 钉死哈希比对 ----------
if [ -n "${PACKAGE_SHA256}" ]; then
  bash "${ROOT_DIR}/scripts/build-release-bundle.sh" >/dev/null
  BUNDLE="${ROOT_DIR}/dist/${PACKAGE_NAME}"
  ACTUAL="$(${SHA_BIN} "${BUNDLE}" | awk '{print $1}')"
  if [ "${ACTUAL}" = "${PACKAGE_SHA256}" ]; then
    ok "bundle SHA256=${ACTUAL} 与 install.sh 钉死值一致"
  else
    bad "bundle SHA256=${ACTUAL} 与 install.sh 钉死值 ${PACKAGE_SHA256} 不一致"
  fi
  CHK="$(sed -n 's/^\([0-9a-f]\{64\}\)  '"${PACKAGE_NAME}"'$/\1/p' "${ROOT_DIR}/dist/checksums.txt" | head -n1)"
  if [ -n "${CHK}" ] && [ "${CHK}" = "${ACTUAL}" ]; then
    ok "dist/checksums.txt 与 bundle 一致"
  else
    bad "dist/checksums.txt 与 bundle 不一致（期望 ${ACTUAL}）"
  fi
  if tar -tzf "${BUNDLE}" | grep -qx "${REPO_NAME}-${VERSION}/cdn.sh"; then
    ok "bundle 内含 cdn.sh"
  else
    bad "bundle 缺少 cdn.sh"
  fi
  # 随包离线 CDN 网段清单：源文件存在 + 已打入 bundle
  S_FILES="$(sed -n 's/^CDN_CDNIP_FILES="\${CDN_CDNIP_FILES:-\(.*\)}"$/\1/p' "${ROOT_DIR}/cdn.sh")"
  if [ -n "${S_FILES}" ] && [ "${S_FILES}" = "${CDN_CDNIP_FILES}" ]; then
    ok "install.sh 与 cdn.sh 的 CDN 网段清单文件列表一致"
  else
    bad "install.sh 与 cdn.sh 的 CDN 网段清单文件列表不一致（install=${CDN_CDNIP_FILES:-空} / cdn=${S_FILES:-空}）"
  fi
  BUNDLED_MISSING=0
  n=0
  for f in ${CDN_CDNIP_FILES}; do
    n=$((n + 1))
    if [ ! -f "${ROOT_DIR}/${f}" ]; then
      bad "缺少 CDN 网段清单源文件：${f}"
      BUNDLED_MISSING=1
    fi
    if ! tar -tzf "${BUNDLE}" | grep -qx "${REPO_NAME}-${VERSION}/${f}"; then
      bad "bundle 缺少随包 CDN 网段清单：${f}"
      BUNDLED_MISSING=1
    fi
  done
  if [ "${BUNDLED_MISSING}" = "0" ] && [ "${n}" -gt 0 ]; then
    ok "bundle 内含 ${n} 个随包 CDN 网段清单 txt（离线可用）"
  fi
else
  bad "install.sh 缺少 PACKAGE_SHA256（尚未回填）"
fi

echo ""
echo "check-version 结果：${PASS} 通过 / ${FAIL} 失败"
[ "${FAIL}" = "0" ] || exit 1