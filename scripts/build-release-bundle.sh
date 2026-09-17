#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' <"${ROOT_DIR}/VERSION")"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_DIR="${DIST_DIR}/gcp_traffic_routing-${VERSION}"
PACKAGE_NAME="gcp_traffic_routing-${VERSION}.tar.gz"

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}" "${DIST_DIR}"

install -m 0755 "${ROOT_DIR}/cdn.sh" "${PACKAGE_DIR}/cdn.sh"
install -m 0644 "${ROOT_DIR}/README.md" "${PACKAGE_DIR}/README.md"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

# 显式钉死权限位：部分平台（MSYS）的 install -m 不生效而直接沿用源文件 mode，
# 为保证跨平台字节一致，统一以 chmod 兜底（chmod 两平台语义一致）。
chmod 0644 "${PACKAGE_DIR}/VERSION" "${PACKAGE_DIR}/README.md"
chmod 0755 "${PACKAGE_DIR}/cdn.sh"

# 归一化 tar 元数据并用 gzip -n 去除时间戳，保证同一内容构建出字节级一致的 bundle。
# --format=gnu：显式钉死归档格式（GNU tar 1.34 前默认 gnu；1.35 起部分发行版默认
# 改为 posix/pax），否则跨平台会因默认格式不同而产出不同字节。
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -cf - -C "${DIST_DIR}" "gcp_traffic_routing-${VERSION}" | gzip -n >"${DIST_DIR}/${PACKAGE_NAME}"

(
  cd "${DIST_DIR}"
  # 归一化为 "hash␣␣文件名"（双空格、无二进制标记 *），与 install.sh 的解析逻辑严格一致
  awk -v name="${PACKAGE_NAME}" '{ print $1 "  " name }' < <(sha256sum "${PACKAGE_NAME}") >checksums.txt
)

echo "Built ${DIST_DIR}/${PACKAGE_NAME}"