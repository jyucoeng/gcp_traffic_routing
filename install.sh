#!/usr/bin/env bash
set -eEuo pipefail

umask 077

REPO_OWNER="jyucoeng"
REPO_NAME="gcp_traffic_routing"
PROJECT_VERSION="v0.1.0"
PACKAGE_NAME="gcp_traffic_routing-v0.1.0.tar.gz"
# 发布流程：scripts/build-release-bundle.sh 构建可复现 bundle，其 SHA256 与此处一致
PACKAGE_SHA256=""
PACKAGE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${PROJECT_VERSION}/${PACKAGE_NAME}"

CDN_BIN="/usr/local/bin/cdn"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行。" >&2
  exit 1
fi

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "需要安装 curl 或 wget。" >&2
    exit 1
  fi
}

sha256_file() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    openssl dgst -sha256 "$target" | awk '{print $2}'
  fi
}

verify_bundle() {
  local bundle="$1"
  local actual
  actual="$(sha256_file "$bundle")"
  if [ "$actual" != "$PACKAGE_SHA256" ]; then
    echo "安装包校验失败。" >&2
    echo "预期值: $PACKAGE_SHA256" >&2
    echo "实际值: $actual" >&2
    exit 1
  fi
}

install_bundle() {
  local bundle="$1"
  local tmpdir root_dir

  tmpdir="$(mktemp -d)"
  tar -xzf "$bundle" -C "$tmpdir"
  root_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "$root_dir" ]; then
    rm -rf "$tmpdir"
    echo "发布包结构异常：未找到根目录。" >&2
    exit 1
  fi

  if ! bash -n "${root_dir}/cdn.sh"; then
    rm -rf "$tmpdir"
    echo "发布包脚本语法校验失败，已取消安装。" >&2
    exit 1
  fi

  install -m 0755 "${root_dir}/cdn.sh" "${CDN_BIN}"
  chmod 0755 "${CDN_BIN}"
  rm -rf "$tmpdir"
}

main() {
  local bundle
  bundle="$(mktemp)"
  if ! download "${PACKAGE_URL}" "${bundle}"; then
    rm -f "${bundle}"
    echo "下载发布包失败：${PACKAGE_URL}" >&2
    exit 1
  fi
  verify_bundle "${bundle}"
  install_bundle "${bundle}"
  rm -f "${bundle}"
  echo "gcp_traffic_routing ${PROJECT_VERSION} 安装完成：${CDN_BIN}"

  # 设了 cdnt 即自动初始化（安装 dae + geoip + 生成配置）
  if [ -n "${cdnt:-}" ]; then
    bash "${CDN_BIN}" || {
      echo "gcp_traffic_routing 初始化失败。" >&2
      exit 1
    }
  fi
}

main "$@"