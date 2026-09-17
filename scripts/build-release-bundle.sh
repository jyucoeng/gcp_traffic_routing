#!/usr/bin/env bash
set -eEuo pipefail

# =============================================================================
# 发布包构建脚本 —— 生成字节级可复现的 tar.gz 发布包。
# 项目名/版本从 install.sh 与 VERSION 读取（单一事实源），
# Fork 后改写 install.sh 顶部 REPO_NAME 即可，本脚本无需改动。
# =============================================================================
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' <"${ROOT_DIR}/VERSION")"
PROJECT_NAME="$(sed -n 's/^REPO_NAME="\([^"]*\)".*/\1/p' "${ROOT_DIR}/install.sh")"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_DIR="${DIST_DIR}/${PROJECT_NAME}-${VERSION}"
PACKAGE_NAME="${PROJECT_NAME}-${VERSION}.tar.gz"

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}" "${DIST_DIR}"

install -m 0755 "${ROOT_DIR}/cdn.sh" "${PACKAGE_DIR}/cdn.sh"
install -m 0644 "${ROOT_DIR}/README.md" "${PACKAGE_DIR}/README.md"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

# 显式钉死权限位：部分平台（MSYS）的 install -m 不生效而直接沿用源文件 mode，
# 为保证跨平台字节一致，统一以 chmod 兜底（chmod 两平台语义一致）。
# 包目录本身也须钉死：其 mode 由调用者 umask 决定，若不强制 0755，
# 则 tar 记录的目录权限随 umask 变化，破坏"同源字节可复现"。
chmod 0755 "${PACKAGE_DIR}" "${PACKAGE_DIR}/cdn.sh"
chmod 0644 "${PACKAGE_DIR}/VERSION" "${PACKAGE_DIR}/README.md"

# 归一化 tar 元数据并用 gzip -n 去除时间戳，保证同一内容构建出字节级一致的 bundle。
# --format=gnu：显式钉死归档格式（GNU tar 1.34 前默认 gnu；1.35 起部分发行版默认
# 改为 posix/pax），否则跨平台会因默认格式不同而产出不同字节。
# 本脚本需要 GNU tar（macOS 自带 bsdtar 不支持 --sort=name），优先 gtar，其次 GNU tar。
if command -v gtar >/dev/null 2>&1; then
  TAR_BIN="gtar"
elif tar --version 2>/dev/null | grep -q "GNU tar"; then
  TAR_BIN="tar"
else
  echo "需要 GNU tar（macOS 请先安装：brew install gnu-tar）" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  SHA_BIN="sha256sum"
else
  SHA_BIN="shasum -a 256"
fi

"${TAR_BIN}" --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -cf - -C "${DIST_DIR}" "${PROJECT_NAME}-${VERSION}" | gzip -n >"${DIST_DIR}/${PACKAGE_NAME}"

(
  cd "${DIST_DIR}"
  # 归一化为 "hash␣␣文件名"（双空格、无二进制标记 *），与 install.sh 的解析逻辑严格一致
  awk -v name="${PACKAGE_NAME}" '{ print $1 "  " name }' < <(${SHA_BIN} "${PACKAGE_NAME}") >checksums.txt
)

echo "Built ${DIST_DIR}/${PACKAGE_NAME}"