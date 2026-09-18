#!/usr/bin/env bash
# SCRIPT_VERSION 由 scripts/check-version.sh 外部读取做版本一致性门禁，豁免 SC2034。
# shellcheck disable=SC2034
set -eEuo pipefail

###############################################################################
# gcp_traffic_routing —— 独立项目：GCP 出站 CDN 流量分流管理器（dae 透明代理）
# 与 Singbox Manager / MTProxy 无任何依赖关系，本脚本自包含。
#
# 背景：GCP 免费实例的出站流量对部分 CDN 网段（Cloudflare/Fastly/Akamai 等，
# geodata 中的 cdnip 标签）单独计费且很贵。本脚本在本机安装 dae（eBPF 透明
# 代理），按"目的 IP 是否命中 cdnip 网段"分流：命中的统统治经你提供的
# vless/vmess/trojan/hysteria2/tuic/anytls 节点（免费/便宜节点）中转，其余流量直连，从而避免 GCP
# 对本机
# 到 CDN 出站的高额计费。
#
# 命令:
#   cdn              同 install（TTY 下显示交互菜单：1安装 2设置分流节点 3全量卸载 4退出）
#   cdn install      安装/更新 dae + cdnip geoip 数据库 + 在线 CDN 网段缓存，并生成配置
#   cdn update       强制重下 dae 二进制与 geoip 数据库 + CDN 网段缓存，然后重新 apply
#   cdn add <链接...>      添加节点（vless/vmess/trojan/hysteria2/tuic/anytls），自动 apply
#   cdn add-sub <url> [标签]  添加订阅，自动 apply
#   cdn del <匹配>         按序号(1 起)或关键字删除节点，自动 apply
#   cdn del-sub <匹配>     按序号或关键字删除订阅，自动 apply
#   cdn list         列出已存节点/订阅（凭据掩码）与服务状态
#   cdn render       仅把配置渲染到 stdout（不写盘、不重启）
#   cdn apply        渲染并校验 config.dae，写盘后重启 dae 服务
#   cdn restart|stop|start  控制 dae 服务
#   cdn status       查看 dae 服务状态
#   cdn log          查看 dae 最近日志
#   cdn un           全量卸载并清理
#   cdn menu         显示交互菜单
#   cdn -h|--help|help  显示帮助（服务/二进制/geo/配置/节点）
#
# 环境变量:
#   node1..nodeN      install 时预填节点链接
#   sub1..subN        install 时预填订阅链接
#   cdn_policy        my_group 节点选择策略（min/random/min_avg10/min_moving_avg/fixed(0)...）
#   cdn_geoip_url     自定义 geoip.dat 下载地址（默认社区 cdnip 版）
#   cdn_geoip_sha_url 自定义 sha256 校验文件地址（默认 "${cdn_geoip_url}.sha256sum"）
#   cdn_skip_geo      跳过 geoip 下载（仅当你已自行放置 /usr/local/share/dae/geoip.dat）
#   cdn_cdnip_base    在线 CDN 网段清单 base URL（默认 jyucoeng/gcp_traffic_routing main）
#   cdn_cdnip_files   清单文件名列表（可覆盖，空格分隔）
#   cdn_skip_cdnip    跳过 CDN 网段清单下载（降级为仅 geoip 判定）
#   cdn_force         强制重装，跳过"已存在"判断（cdn update 内部使用）
#   CDN_DAE_VERSION_URL 自定义 dae 版本查询接口（默认 GitHub API）
#   CDN_DIR           工作目录（默认 /usr/local/etc/cdn-manager；测试可覆盖）
#   CDN_CONF          配置输出路径（默认 /usr/local/etc/dae/config.dae；测试可覆盖）
###############################################################################

SCRIPT_VERSION="0.1.0"

# 项目显示名（菜单标题等处使用）。Fork 本仓库后如想改显示名，改这里即可；
# 但发布包/安装脚本的仓库名仍以 install.sh 顶部 REPO_NAME 为准。
PROJECT_NAME="gcp_traffic_routing"

DAE_BIN="${DAE_BIN:-/usr/local/bin/dae}"
DAE_DATA_DIR="/usr/local/share/dae"
DAE_GEOIP="${DAE_DATA_DIR}/geoip.dat"
CDN_DIR="${CDN_DIR:-/usr/local/etc/cdn-manager}"
CDN_CONF="${CDN_CONF:-/usr/local/etc/dae/config.dae}"
CDN_NODES="${CDN_DIR}/nodes.list"
CDN_SUBS="${CDN_DIR}/subs.list"
CDN_SERVICE="dae"
CDN_SYSTEMD_FILE="/etc/systemd/system/dae.service"
CDN_OPENRC_FILE="/etc/init.d/dae"
INIT_SYSTEM=""
DAE_ARCH_CANDIDATES=()

# 与参考实现（fatekey/gcp_free）同源的社区 cdnip geoip 数据库
CDN_GEOIP_URL_DEFAULT="https://github.com/fatekey/gcp_free/raw/master/geoip.dat"
CDN_GEOIP_SHA_DEFAULT="${CDN_GEOIP_URL_DEFAULT}.sha256sum"
CDN_GEOIP_MIRROR="https://cdn.jsdelivr.net/gh/fatekey/gcp_free@master/geoip.dat"

# 在线 CDN 网段 txt 清单（托管于 jyucoeng/gcp_traffic_routing 仓库，不会随意删除；
# 不随本发布包分发，安装/更新时在线拉取）。对应 Cloudflare/Fastly/Akamai 的
# v4+v6 官方网段，每行为一条逗号/换行分隔的 CIDR 列表。
# render 时生成 dip(ipcidr(...)) 规则并置于 dip(geoip:cdnip) 之前：
#   命中该缓存 -> 直接走 CDN 组；未命中 -> 继续查 geoip.dat(cdnip)。
CDN_CDNIP_BASE="${CDN_CDNIP_BASE:-https://raw.githubusercontent.com/jyucoeng/gcp_traffic_routing/main}"
CDN_CDNIP_FILES="${CDN_CDNIP_FILES:-1-cfcdn-ip-15.txt 1-cfcdn-ipv6-7.txt 2-fastly-ip-19.txt 2-fastly-ipv6-2.txt 3-akamai_ipv6-64.txt 4-akamai-ip-255.txt 5-akamai-ip-113.txt}"
CDN_CDNIP_CACHE="${CDN_CDNIP_CACHE:-${DAE_DATA_DIR}/cdnip.txt}"

# 颜色输出（非 TTY 或 NO_COLOR 时禁用）
supports_color() {
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then return 1; fi
  return 0
}

GREEN=""
RED=""
YELLOW=""
BLUE=""
PLAIN=""
if supports_color; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  PLAIN=$'\033[0m'
fi

cdn_print_ok() { echo -e "${GREEN}[OK] $*${PLAIN}"; }
cdn_print_info() { echo -e "${BLUE}[INFO] $*${PLAIN}"; }
cdn_print_warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }
cdn_print_err() { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; }

cdn_fatal() {
  cdn_print_err "$*"
  exit 1
}

is_num() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

command_exists() { command -v "$1" >/dev/null 2>&1; }

download_file() {
  local url="$1" out="$2"
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    cdn_fatal "需要安装 curl 或 wget 才能下载文件。"
  fi
}

sha256_file() {
  if command_exists sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $2}' || true
  fi
}

sha256_str() {
  local out=""
  if command_exists sha256sum; then
    out="$(printf '%s' "$1" | sha256sum 2>/dev/null)"
  elif command_exists shasum; then
    out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)"
  fi
  printf '%s' "${out}" | awk '{print $1}'
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    cdn_fatal "需要 root 权限，请使用 sudo 或以 root 身份运行。"
  fi
}

# 检测 init 系统
detect_init_system() {
  if [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif [ -f /sbin/openrc-run ] || [ -f /etc/alpine-release ]; then
    INIT_SYSTEM="openrc"
  elif [ -f /etc/init.d/rcS ] && command -v service >/dev/null 2>&1; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
}

# dae 基于 eBPF，容器内无法运行（与参考安装脚本同款容器白名单判定）
cdn_check_container() {
  local virt=""
  if command_exists systemd-detect-virt; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  case "${virt}" in
  openvz | lxc | lxc-libvirt | wsl | docker | podman | systemd-nspawn | proot | rkt | rouch)
    cdn_fatal "检测到容器运行时（${virt}），dae（eBPF 透明代理）不支持容器内安装。"
    ;;
  esac
}

# dae 的 eBPF 程序需要内核 BTF 信息
cdn_check_btf() {
  if [ ! -r /sys/kernel/btf/vmlinux ]; then
    cdn_print_warn "未检测到 /sys/kernel/btf/vmlinux（内核需开启 CONFIG_DEBUG_INFO_BTF），dae 可能无法加载 eBPF。"
  fi
}

# 映射本机架构到 dae 发布包架构名（x86_64 带 v2/v3 变体，逐候选回退）
cdn_arch_candidates() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
  amd64 | x86_64)
    if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
      DAE_ARCH_CANDIDATES=("x86_64_v3_avx2" "x86_64_v2_sse" "x86_64")
    else
      DAE_ARCH_CANDIDATES=("x86_64_v2_sse" "x86_64")
    fi
    ;;
  aarch64 | arm64)
    DAE_ARCH_CANDIDATES=("arm64" "armv8")
    ;;
  armv7l | armv7)
    DAE_ARCH_CANDIDATES=("armv7")
    ;;
  i386 | i686)
    DAE_ARCH_CANDIDATES=("x86_32")
    ;;
  *)
    cdn_fatal "不支持的 CPU 架构：${machine}"
    ;;
  esac
}

# 获取 dae 最新版本号（GitHub API 优先，限流时回退 releases/latest 跳转解析）
cdn_latest_version() {
  local tmp ver=""
  if command_exists curl; then
    tmp="$(mktemp)"
    if curl -fsSL --max-time 15 "${CDN_DAE_VERSION_URL:-https://api.github.com/repos/daeuniverse/dae/releases/latest}" -o "${tmp}" 2>/dev/null; then
      ver="$(grep -m1 '"tag_name"' "${tmp}" | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    fi
    rm -f "${tmp}"
    if [ -z "${ver}" ]; then
      ver="$(curl -sIL --max-time 15 -o /dev/null -w '%{url_effective}' https://github.com/daeuniverse/dae/releases/latest 2>/dev/null | sed -E 's#.*/tag/(v[0-9][^/]*)$#\1#')"
    fi
  else
    ver="$(wget -qO- --max-redirect=2 "${CDN_DAE_VERSION_URL:-https://api.github.com/repos/daeuniverse/dae/releases/latest}" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  fi
  [ -n "${ver}" ] || cdn_fatal "无法获取 dae 最新版本号。"
  printf '%s\n' "${ver}"
}

# 下载并校验 dae 二进制（SHA256 与上游 .dgst 对齐，校验失败则回退下一候选架构）
cdn_install_binary() {
  local ver arch url tmp work zip dgst cur_dir bin bin_tmp local_sha remote_sha ok=0 done=""
  if [ "${cdn_force:-0}" != "1" ] && [ -x "${DAE_BIN}" ] && "${DAE_BIN}" --version >/dev/null 2>&1; then
    cdn_print_info "dae 已安装：$("${DAE_BIN}" --version 2>/dev/null | head -n1)"
    return 0
  fi
  ver="$(cdn_latest_version)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  for arch in "${DAE_ARCH_CANDIDATES[@]}"; do
    url="https://github.com/daeuniverse/dae/releases/download/${ver}/dae-linux-${arch}.zip"
    cdn_print_info "下载 dae-linux-${arch}（${ver}）..."
    zip="${tmp}/dae.zip"
    dgst="${tmp}/dae.zip.dgst"
    rm -f "${zip}" "${dgst}"
    if ! download_file "${url}" "${zip}"; then
      cdn_print_warn "下载失败，回退下一候选架构：${url}"
      continue
    fi
    if ! download_file "${url}.dgst" "${dgst}"; then
      cdn_print_warn "未获取到校验文件（${url}.dgst），回退下一候选架构。"
      rm -f "${zip}"
      continue
    fi
    local_sha="$(sha256_file "${zip}")"
    remote_sha="$(grep -oE '[0-9a-fA-F]{64}' "${dgst}" | head -n1 || true)"
    if [ -z "${local_sha}" ] || [ -z "${remote_sha}" ] || [ "${local_sha}" != "${remote_sha}" ]; then
      cdn_print_warn "SHA256 校验不一致，回退下一候选架构。"
      rm -f "${zip}" "${dgst}"
      continue
    fi
    work="${tmp}/x"
    rm -rf "${work}"
    mkdir -p "${work}"
    if ! unzip -q -o "${zip}" -d "${work}"; then
      cdn_print_warn "解压失败，回退下一候选架构。"
      rm -rf "${work}" "${zip}"
      continue
    fi
    bin="$(find "${work}" -type f -name 'dae-linux-*' | head -n1 || true)"
    if [ -z "${bin}" ] || ! "${bin}" --version >/dev/null 2>&1; then
      cdn_print_warn "解压产物不可执行，回退下一候选架构。"
      rm -rf "${work}" "${zip}"
      continue
    fi
    bin_tmp="${DAE_BIN}.tmp.$$"
    install -m 0755 "${bin}" "${bin_tmp}"
    mv -f "${bin_tmp}" "${DAE_BIN}"
    ok=1
    done="${arch}"
    break
  done
  trap - EXIT
  rm -rf "${tmp}"
  [ "${ok}" = "1" ] || cdn_fatal "dae 下载与校验全部失败，请检查网络后重试。"
  cdn_print_ok "dae ${ver}（${done}）安装完成：${DAE_BIN}"
}

# 下载 cdnip 版 geoip.dat 并校验（优先 GitHub raw，失败回退 jsDelivr 镜像）
cdn_install_geoip() {
  local urls sha_url tmp local_sha remote_sha ok=0
  if [ "${cdn_skip_geo:-0}" = "1" ]; then
    cdn_print_info "cdn_skip_geo=1，跳过 geoip 下载（请确保已放置 ${DAE_GEOIP}）。"
    return 0
  fi
  if [ "${cdn_force:-0}" != "1" ] && [ -s "${DAE_GEOIP}" ]; then
    cdn_print_info "geoip.dat 已存在（${DAE_GEOIP}），跳过下载。"
    return 0
  fi
  if [ -n "${cdn_geoip_url:-}" ]; then
    urls=("${cdn_geoip_url}")
  else
    urls=("${CDN_GEOIP_URL_DEFAULT}" "${CDN_GEOIP_MIRROR}")
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  for url in "${urls[@]}"; do
    sha_url="${cdn_geoip_sha_url:-${url}.sha256sum}"
    cdn_print_info "下载 geoip.dat（${url}）..."
    if ! download_file "${url}" "${tmp}/geoip.dat"; then
      cdn_print_warn "geoip.dat 下载失败，尝试下一地址。"
      continue
    fi
    if ! download_file "${sha_url}" "${tmp}/geoip.dat.sha256sum"; then
      cdn_print_warn "geoip 校验文件下载失败，尝试下一地址。"
      continue
    fi
    local_sha="$(sha256_file "${tmp}/geoip.dat")"
    remote_sha="$(awk '{print $1}' <"${tmp}/geoip.dat.sha256sum" | head -n1 || true)"
    if [ -z "${local_sha}" ] || [ -z "${remote_sha}" ] || [ "${local_sha}" != "${remote_sha}" ]; then
      cdn_print_warn "geoip.dat SHA256 不一致，尝试下一地址。"
      continue
    fi
    mkdir -p "${DAE_DATA_DIR}"
    install -m 0644 "${tmp}/geoip.dat" "${DAE_GEOIP}"
    ok=1
    break
  done
  trap - EXIT
  rm -rf "${tmp}"
  [ "${ok}" = "1" ] || cdn_fatal "geoip.dat（cdnip）下载与校验全部失败。"
  cdn_print_ok "geoip.dat（cdnip 标签）已安装：${DAE_GEOIP}"
}

# 下载并缓存在线 CDN 网段清单（逗号/换行分隔 CIDR，含 v4+v6），
# 供 render 生成 ipcidr 规则作为 geoip.dat 之前的第一层命中判定。
# 失败仅告警不中断：降级为纯 geoip(cdnip) 判定。
cdn_fetch_cdnip() {
  local f url tmp cidr raw="" out=()
  if [ "${cdn_skip_cdnip:-0}" = "1" ]; then
    cdn_print_info "cdn_skip_cdnip=1，跳过 CDN 网段清单下载。"
    return 0
  fi
  if [ "${cdn_force:-0}" != "1" ] && [ -s "${CDN_CDNIP_CACHE}" ]; then
    cdn_print_info "CDN 网段缓存已存在（$(wc -l <"${CDN_CDNIP_CACHE}") 条）：${CDN_CDNIP_CACHE}"
    return 0
  fi
  [ "${CDN_TEST_MODE:-0}" = "1" ] && {
    cdn_print_info "测试模式：跳过 CDN 网段清单在线下载。"
    return 0
  }
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  for f in ${CDN_CDNIP_FILES}; do
    url="${CDN_CDNIP_BASE}/${f}"
    if download_file "${url}" "${tmp}/${f}" 2>/dev/null; then
      raw="${raw} $(tr ',' '\n' <"${tmp}/${f}")"
    else
      cdn_print_warn "CDN 网段清单下载失败：${url}"
    fi
  done
  trap - EXIT
  rm -rf "${tmp}"
  raw="$(printf '%s' "${raw}" | tr ' ' '\n' | awk 'NF{gsub(/^[ \t\r]+|[ \t\r]+$/, ""); print}')"
  if [ -z "${raw}" ]; then
    cdn_print_warn "未获取到任何 CDN 网段，降级为仅使用 geoip.dat（cdnip）判定。"
    return 0
  fi
  while IFS= read -r cidr; do
    [ -z "${cidr}" ] && continue
    if printf '%s' "${cidr}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$|^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|12[0-8])$'; then
      out+=("${cidr}")
    else
      cdn_print_warn "忽略非法网段：${cidr}"
    fi
  done <<<"${raw}"
  [ "${#out[@]:-0}" -gt 0 ] || {
    cdn_print_warn "CDN 网段清单全部非法，降级为仅使用 geoip.dat（cdnip）判定。"
    return 0
  }
  mkdir -p "$(dirname "${CDN_CDNIP_CACHE}")"
  printf '%s\n' "${out[@]}" | sort -u >"${CDN_CDNIP_CACHE}"
  cdn_print_ok "CDN 网段清单已缓存（$(wc -l <"${CDN_CDNIP_CACHE}") 条）：${CDN_CDNIP_CACHE}"
}

# 从缓存生成 dip(ipcidr(...)) 规则行（每行至多 25 条 CIDR），
# 由 render 插入在 dip(geoip:cdnip) 之前：先命中缓存，未命中再查 geoip。
cdn_ipcidr_rules() {
  local group=() n=0 cidr
  [ -s "${CDN_CDNIP_CACHE}" ] || cdn_fetch_cdnip >/dev/null 2>&1 || true
  [ -s "${CDN_CDNIP_CACHE}" ] || return 0
  while IFS= read -r cidr; do
    [ -z "${cidr}" ] && continue
    printf '%s' "${cidr}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$|^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|12[0-8])$' || continue
    group+=("${cidr}")
    n=$((n + 1))
    if [ "${n}" -ge 25 ]; then
      printf '    dip(ipcidr(%s)) -> my_group\n' "$(IFS=,; printf '%s' "${group[*]}")"
      group=() n=0
    fi
  done <"${CDN_CDNIP_CACHE}"
  if [ "${n}" -gt 0 ]; then
    printf '    dip(ipcidr(%s)) -> my_group\n' "$(IFS=,; printf '%s' "${group[*]}")"
  fi
}

# 自动探测 LAN 接口：存在 docker 网桥（docker0/br-*，参考实现同款）时绑定，否则留空
cdn_detect_lan_iface() {
  local dir oper
  for dir in docker0 /sys/class/net/br-*; do
    [ -d "/sys/class/net/${dir}" ] || continue
    oper="$(cat "/sys/class/net/${dir}/operstate" 2>/dev/null || true)"
    if [ "${oper:-down}" = "up" ]; then
      printf '%s' "${dir}"
      return 0
    fi
  done
  return 0
}

# 节点链接校验：接受 vless / vmess / trojan / hysteria2 / tuic / anytls（其余协议不在本脚本支持范围）
cdn_valid_link() {
  case "$1" in
  vless://* | vmess://* | trojan://* | hysteria2://* | tuic://* | anytls://*)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

cdn_read_nodes() {
  [ -f "${CDN_NODES}" ] && grep -vE '^[[:space:]]*$' "${CDN_NODES}" || true
}

cdn_read_subs() {
  [ -f "${CDN_SUBS}" ] && grep -vE '^[[:space:]]*$' "${CDN_SUBS}" || true
}

# 节点链接掩码显示：协议 + 掩码凭据摘要 + host:port（剥离 query 与 # 片段）
# vmess 为标准 Base64(JSON) 链接、无 @host:port 结构，整段均视为凭据 → 整体掩码。
cdn_mask_link() {
  local link="$1" proto rest hostport secret fp clean
  proto="${link%%://*}"
  rest="${link#*://}"
  hostport="${rest#*@}"
  secret="${rest%%@*}"
  clean="${hostport%%\?*}"
  clean="${clean%%#*}"
  if [ "${secret}" != "${rest}" ] && [ -n "${secret}" ]; then
    fp="$(sha256_str "${secret}")"
    printf '%s://#%s@%s' "${proto}" "${fp:0:6}" "${clean}"
  elif [ "${proto}" = "vmess" ] && [ -n "${rest}" ]; then
    fp="$(sha256_str "${rest}")"
    printf '%s://#%s' "${proto}" "${fp:0:6}"
  else
    printf '%s://%s' "${proto}" "${clean}"
  fi
}

cdn_mask_sub() {
  local url="$1"
  printf '%s' "${url}" | sed -E 's#(https?://[^/]+)/.*#\1/…#'
}

# 渲染完整 config.dae（纯函数，仅打印到 stdout）
cdn_render_config() {
  local policy lan line i label url nodes subs
  policy="${cdn_policy:-min}"
  case "${policy}" in
  min | random | min_avg10 | min_moving_avg | fixed*) ;;
  *)
    cdn_fatal "cdn_policy 非法：${policy}（可用 min/random/min_avg10/min_moving_avg/fixed(0)）"
    ;;
  esac
  lan="$(cdn_detect_lan_iface)"
  nodes="$(cdn_read_nodes)"
  subs="$(cdn_read_subs)"

  printf 'global {\n'
  printf '    log_level: info\n'
  printf '    wan_interface: auto\n'
  if [ -n "${lan}" ]; then
    printf '    lan_interface: %s\n' "${lan}"
  fi
  printf '    auto_config_kernel_parameter: true\n'
  printf '    allow_insecure: true\n'
  printf '}\n'
  printf 'dns {\n'
  printf '    upstream {\n'
  printf "        googledns: 'tcp+udp://dns.google:53'\n"
  printf '    }\n'
  printf '    routing {\n'
  printf '        request {\n'
  printf '            qtype(https) -> reject\n'
  printf '            fallback: googledns\n'
  printf '        }\n'
  printf '    }\n'
  printf '}\n'
  printf 'group {\n'
  printf '    my_group {\n'
  printf '        policy: %s\n' "${policy}"
  printf '    }\n'
  printf '}\n'
  printf 'routing {\n'
  printf '    pname(NetworkManager) -> direct\n'
  printf '    # 第一层：在线 CDN 网段缓存命中即走 CDN 组（未命中再查 geoip.dat）\n'
  cdn_ipcidr_rules
  printf '    dip(geoip:cdnip) -> my_group\n'
  printf '\n'
  printf '    fallback: direct\n'
  printf '}\n'
  printf 'node {\n'
  i=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    i=$((i + 1))
    printf "    '%s'\n" "${line}"
  done <<<"${nodes}"
  printf '}\n'
  printf 'subscription {\n'
  i=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    i=$((i + 1))
    label="sub_${i}"
    url="${line}"
    if [[ "${line}" =~ ^([A-Za-z0-9_-]+):(https?://.*)$ ]]; then
      label="${BASH_REMATCH[1]}"
      url="${BASH_REMATCH[2]}"
    fi
    printf "    %s: '%s'\n" "${label}" "${url}"
  done <<<"${subs}"
  printf '}\n'
}

# 渲染并写盘 config.dae；有节点/订阅时先经 dae validate 校验
cdn_write_config() {
  local tmp has_content
  mkdir -p "$(dirname "${CDN_CONF}")"
  tmp="$(mktemp /tmp/cdnconfig.XXXXXX.dae)"
  cdn_render_config >"${tmp}"
  if grep -qE "^\s*'vless://|^\s*'trojan://|^\s*sub_[0-9]+:|^\s*[A-Za-z0-9_-]+: 'https?://" "${tmp}"; then
    has_content=1
  fi
  if [ "${has_content:-0}" = "1" ] && [ -x "${DAE_BIN}" ]; then
    if ! "${DAE_BIN}" validate -c "${tmp}" >/dev/null 2>&1; then
      cdn_print_err "配置校验失败，未写盘，服务保持不变："
      "${DAE_BIN}" validate -c "${tmp}" 2>&1 || true
      rm -f "${tmp}"
      return 1
    fi
  fi
  install -m 0600 "${tmp}" "${CDN_CONF}"
  rm -f "${tmp}"
  cdn_print_ok "配置已写入：${CDN_CONF}"
  return 0
}

cdn_create_service() {
  if [ "${INIT_SYSTEM}" = "systemd" ]; then
    if [ ! -f "${CDN_SYSTEMD_FILE}" ]; then
      cat >"${CDN_SYSTEMD_FILE}" <<EOF
[Unit]
Description=dae transparent proxy (CDN traffic split)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DAE_BIN} run -c ${CDN_CONF}
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      cdn_print_ok "systemd 服务已创建：${CDN_SERVICE}.service"
    fi
  elif [ "${INIT_SYSTEM}" = "openrc" ]; then
    if [ ! -f "${CDN_OPENRC_FILE}" ]; then
      cat >"${CDN_OPENRC_FILE}" <<EOF
#!/sbin/openrc-run
name="${CDN_SERVICE}"
description="dae transparent proxy (CDN traffic split)"
command="${DAE_BIN}"
command_args="run -c ${CDN_CONF}"
pidfile="/run/${CDN_SERVICE}.pid"
command_background="true"
rc_ulimit="-n 65535"

depend() {
    need net
}
EOF
      chmod +x "${CDN_OPENRC_FILE}"
      cdn_print_ok "OpenRC 服务已创建：${CDN_SERVICE}"
    fi
  fi
}

cdn_service_start() {
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl enable --now "${CDN_SERVICE}"
    ;;
  openrc)
    rc-update add "${CDN_SERVICE}" default >/dev/null 2>&1 || true
    rc-service "${CDN_SERVICE}" start
    ;;
  *)
    cdn_print_warn "未检测到 systemd/openrc，跳过开机自启。"
    ;;
  esac
}

cdn_restart_service() {
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl enable "${CDN_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${CDN_SERVICE}"
    ;;
  openrc)
    rc-service "${CDN_SERVICE}" restart
    ;;
  *)
    cdn_print_warn "无服务管理器，请手动重启 dae（dae run -c ${CDN_CONF} &）。"
    ;;
  esac
}

cdn_service_ctl() {
  local action="$1"
  require_root
  detect_init_system
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl "${action}" "${CDN_SERVICE}"
    ;;
  openrc)
    rc-service "${CDN_SERVICE}" "${action}"
    ;;
  *)
    cdn_fatal "未检测到 systemd/openrc，无法控制系统服务。"
    ;;
  esac
  cdn_print_ok "已执行 systemctl/openrc ${action}：${CDN_SERVICE}"
}

cdn_status() {
  local active
  if [ ! -x "${DAE_BIN}" ]; then
    cdn_print_warn "dae 未安装，先运行：cdn install"
    return 1
  fi
  if [ "${INIT_SYSTEM:-}" = "" ]; then
    detect_init_system
  fi
  echo -e "dae 版本: $("${DAE_BIN}" --version 2>/dev/null | head -n1 || echo 未知)"
  case "${INIT_SYSTEM}" in
  systemd)
    active="$(systemctl is-active "${CDN_SERVICE}" 2>/dev/null || echo inactive)"
    echo -e "服务: ${CDN_SERVICE} (systemd) ${GREEN}${active}${PLAIN}"
    ;;
  openrc)
    active="$(rc-service "${CDN_SERVICE}" status 2>/dev/null | grep -qi 'started' && echo started || echo stopped)"
    echo -e "服务: ${CDN_SERVICE} (openrc) ${GREEN}${active}${PLAIN}"
    ;;
  *)
    echo -e "服务: ${CDN_SERVICE}（无服务管理器）"
    ;;
  esac
  echo -e "配置: ${CDN_CONF}（dip(geoip:cdnip) -> my_group）"
  echo -e "节点文件: ${CDN_NODES}$( [ -f "${CDN_NODES}" ] && echo "（$(cdn_read_nodes | wc -l | tr -d ' ') 条）" || echo '（空）' )"
  echo -e "订阅文件: ${CDN_SUBS}$( [ -f "${CDN_SUBS}" ] && echo "（$(cdn_read_subs | wc -l | tr -d ' ') 条）" || echo '（空）' )"
}

cdn_log() {
  if [ "${INIT_SYSTEM:-}" = "" ]; then
    detect_init_system
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    journalctl -u "${CDN_SERVICE}" -n 50 --no-pager 2>/dev/null || journalctl -n 50 --no-pager 2>/dev/null || true
    ;;
  *)
    cdn_print_warn "当前无 journalctl，请在 /var/log 或 dae 日志中查看。"
    ;;
  esac
}

cdn_list() {
  local i line
  echo -e "${BLUE}== 节点（vless/vmess/trojan/hysteria2/tuic/anytls，凭据已掩码）==${PLAIN}"
  if [ -f "${CDN_NODES}" ]; then
    i=0
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      i=$((i + 1))
      echo -e "  [${i}] $(cdn_mask_link "${line}")"
    done <<<"$(cdn_read_nodes)"
    [ "${i}" = "0" ] && echo "  （无）"
  else
    echo "  （无）"
  fi
  echo ""
  echo -e "${BLUE}== 订阅 ==${PLAIN}"
  if [ -f "${CDN_SUBS}" ]; then
    i=0
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      i=$((i + 1))
      label="${line%%:*}"
      url="${line#*:}"
      if [[ "${line}" =~ ^https?:// ]]; then
        label="sub_${i}"
        url="${line}"
      fi
      echo -e "  [${i}] ${label} -> $(cdn_mask_sub "${url}")"
    done <<<"$(cdn_read_subs)"
    [ "${i}" = "0" ] && echo "  （无）"
  else
    echo "  （无）"
  fi
  echo ""
  cdn_status || true
}

cdn_add() {
  cdn_add_impl "node" "$@"
}

cdn_add_sub() {
  cdn_add_impl "sub" "$@"
}

# 通用添加：kind=node / kind=sub
cdn_add_impl() {
  local kind="$1"
  local bad=0
  shift
  if [ "${kind}" = "node" ]; then
    [ $# -ge 1 ] || cdn_fatal "用法: cdn add '<vless://…>' ['<trojan://…>' …]"
    local link
    for link in "$@"; do
      link="${link%\'}"
      link="${link#\'}"
      link="${link%\"}"
      link="${link#\"}"
  if ! cdn_valid_link "${link}"; then
    cdn_print_warn "跳过非法节点链接（仅支持 vless/vmess/trojan/hysteria2/tuic/anytls）：${link:0:60}…"
        bad=1
        continue
      fi
      mkdir -p "${CDN_DIR}"
      : >>"${CDN_NODES}"
      if grep -qxF "${link}" "${CDN_NODES}"; then
        cdn_print_info "节点已存在，跳过：$(cdn_mask_link "${link}")"
        continue
      fi
      printf '%s\n' "${link}" >>"${CDN_NODES}"
      cdn_print_ok "已添加节点：$(cdn_mask_link "${link}")"
    done
    chmod 0600 "${CDN_NODES}" 2>/dev/null || true
  else
    [ $# -ge 1 ] || cdn_fatal "用法: cdn add-sub '<订阅url>' [标签]"
    local url="${1:-}"
    local label="${2:-}"
    case "${url}" in
    http://* | https://*) ;;
    *)
      cdn_print_warn "跳过非法订阅地址：${url}"
      bad=1
      ;;
    esac
    if [ "${bad}" = "0" ]; then
      if [ -n "${label}" ] && ! [[ "${label}" =~ ^[A-Za-z0-9_-]+$ ]]; then
        cdn_print_warn "订阅标签非法（仅字母数字_ -）：${label}"
        bad=1
      fi
    fi
    if [ "${bad}" = "0" ]; then
      mkdir -p "${CDN_DIR}"
      : >>"${CDN_SUBS}"
      if grep -qxF "${url}" "${CDN_SUBS}" || grep -qF ":${url}" "${CDN_SUBS}"; then
        cdn_print_info "订阅已存在，跳过：$(cdn_mask_sub "${url}")"
      else
        printf '%s\n' "${label:+${label}:}${url}" >>"${CDN_SUBS}"
        cdn_print_ok "已添加订阅：${label:-sub_N} -> $(cdn_mask_sub "${url}")"
      fi
      chmod 0600 "${CDN_SUBS}" 2>/dev/null || true
    fi
  fi
  if [ "${bad}" = "0" ]; then
    # CDN_NO_APPLY=1（install 预填阶段）只写数据不触发 apply，由 install 尾部统一执行
    if [ "${CDN_NO_APPLY:-0}" != "1" ]; then
      detect_init_system
      cdn_apply
    fi
  else
    cdn_print_warn "存在非法输入，未触发 apply；校验通过后可手动执行：cdn apply"
  fi
}

cdn_del_impl() {
  local kind="$1"
  local key="$2"
  local file
  if [ "${kind}" = "node" ]; then
    file="${CDN_NODES}"
  else
    file="${CDN_SUBS}"
  fi
  [ -f "${file}" ] || cdn_fatal "无可用${kind}列表（缺少 ${file}）。"
  local line tmp found=0 i=0
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "${line}" ]; do
    i=$((i + 1))
    if [ "${found}" = "0" ] && { { is_num "${key}" && [ "${key}" = "${i}" ]; } || { ! is_num "${key}" && printf '%s' "${line}" | grep -qiF "${key}"; }; }; then
      cdn_print_ok "已删除${kind} [$i]：$( [ "${kind}" = "node" ] && cdn_mask_link "${line}" || echo "${line%%:*}" )"
      found=1
      continue
    fi
    printf '%s\n' "${line}" >>"${tmp}"
  done <"${file}"
  if [ "${found}" = "0" ]; then
    rm -f "${tmp}"
    cdn_fatal "未找到匹配的${kind}：${key}"
  fi
  mv -f "${tmp}" "${file}"
  chmod 0600 "${file}"
  detect_init_system
  cdn_apply
}

cdn_del() {
  [ $# -ge 1 ] || cdn_fatal "用法: cdn del <序号|关键字>"
  cdn_del_impl node "$1"
}

cdn_del_sub() {
  [ $# -ge 1 ] || cdn_fatal "用法: cdn del-sub <序号|关键字>"
  cdn_del_impl sub "$1"
}

cdn_apply() {
  require_root
  detect_init_system
  local nodes subs
  nodes="$(cdn_read_nodes | wc -l | tr -d ' ')"
  subs="$(cdn_read_subs | wc -l | tr -d ' ')"
  if [ "${nodes}${subs}" = "00" ]; then
    cdn_print_warn "尚未添加任何节点/订阅，跳过配置生成。先执行：cdn add '<vless://…|trojan://…|anytls://…>'"
    return 0
  fi
  [ -x "${DAE_BIN}" ] || cdn_fatal "dae 未安装，先执行：cdn install"
  if ! cdn_write_config; then
    cdn_fatal "配置生成/校验失败，服务未变更。"
  fi
  cdn_create_service
  cdn_restart_service
  cdn_print_ok "CDN 分流配置已生效（cdnip 网段缓存 + dip(geoip:cdnip) -> my_group，其余直连）。"
}

cdn_install() {
  require_root
  detect_init_system
  cdn_check_container
  cdn_check_btf
  cdn_arch_candidates
  cdn_install_binary
  cdn_install_geoip
  cdn_fetch_cdnip
  cdn_env_preload
  if [ -f "${CDN_NODES}" ] || [ -f "${CDN_SUBS}" ]; then
    cdn_apply
  else
    cdn_write_config || true
    cdn_print_info "已就绪。接下来用 cdn add 添加节点（vless/vmess/trojan/hysteria2/tuic/anytls），流量将按 CDN 网段缓存 + dip(geoip:cdnip) 分流。"
    cdn_print_info "示例: cdn add 'vless://uuid@node.example.com:443?...' 'trojan://pass@node2.example.com:443'"
  fi
}

cdn_update() {
  require_root
  detect_init_system
  cdn_check_btf
  cdn_arch_candidates
  cdn_force=1 cdn_install_binary
  cdn_force=1 cdn_install_geoip
  cdn_force=1 cdn_fetch_cdnip
  cdn_create_service
  if [ -f "${CDN_NODES}" ] || [ -f "${CDN_SUBS}" ]; then
    cdn_apply
  else
    cdn_write_config || true
  fi
}

# install 阶段从环境变量 node1..nodeN / sub1..subN 预填数据
# 预填时启用 CDN_NO_APPLY=1，避免对每条节点逐次重启 dae，由 install 尾部统一 apply。
cdn_env_preload() {
  local i varname v
  CDN_NO_APPLY=1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    varname="node${i}"
    v="${!varname:-}"
    if [ -n "${v}" ]; then
      cdn_add_impl node "${v}"
    fi
  done
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    varname="sub${i}"
    v="${!varname:-}"
    if [ -n "${v}" ]; then
      cdn_add_impl sub "${v}"
    fi
  done
  unset CDN_NO_APPLY
}

cdn_uninstall() {
  require_root
  detect_init_system
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl disable --now "${CDN_SERVICE}" >/dev/null 2>&1 || true
    rm -f "${CDN_SYSTEMD_FILE}"
    systemctl daemon-reload || true
    ;;
  openrc)
    rc-update del "${CDN_SERVICE}" default >/dev/null 2>&1 || true
    rc-service "${CDN_SERVICE}" stop >/dev/null 2>&1 || true
    rm -f "${CDN_OPENRC_FILE}"
    ;;
  esac
  rm -f "${DAE_BIN}"
  rm -rf "${DAE_DATA_DIR}" /usr/local/etc/dae
  rm -rf "${CDN_DIR}"
  cdn_print_ok "CDN 分流管理器已全量卸载（dae 服务/二进制/geoip/配置/节点/CDN 网段缓存）。"
}

cdn_menu_nodes() {
  local links=() line
  cdn_print_info "请输入 vless:// 或 trojan:// 节点链接（每行一个，空行结束）："
  while :; do
    if ! read -r -p "节点链接> " line || [ -z "${line}" ]; then
      break
    fi
    links+=("${line}")
  done
  if [ "${#links[@]}" -eq 0 ]; then
    cdn_print_warn "未输入任何节点，已返回。"
    return 0
  fi
  cdn_add "${links[@]}"
  cdn_list
}

cdn_menu_uninstall() {
  local ans self
  cdn_print_warn "将彻底删除：dae 服务/二进制 + geoip + CDN 网段缓存 + 配置 + 节点 + 本管理器脚本（${0}）。"
  read -r -p "确认全量卸载？(y/N): " ans || ans=""
  case "${ans:-}" in
  y | Y) ;;
  *)
    cdn_print_info "已取消卸载。"
    return 0
    ;;
  esac
  cdn_uninstall
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  rm -f "${self}" 2>/dev/null || true
  cdn_print_ok "本管理器脚本已一并移除，全量卸载完成。"
  return 1
}

cdn_menu() {
  local choice
  while :; do
    printf '\n%s\n' "${PROJECT_NAME} 管理器（dae CDN 分流）"
    printf '%s\n'   "=============================="
    printf '1) 安装（dae + geoip + CDN 网段缓存 + 配置）\n'
    printf '2) 设置分流节点（vless/vmess/trojan/hysteria2/tuic/anytls）\n'
    printf '3) 全量卸载\n'
    printf '4) 退出\n'
    if ! read -r -p "请选择 [1-4]: " choice; then
      break
    fi
    case "${choice}" in
    1)
      cdn_install
      if [ -t 0 ] && ! cdn_read_nodes | grep -q .; then
        cdn_print_info "尚未添加分流节点，是否现在设置？"
        if read -r -p "(y/N): " _ans && [[ "${_ans}" == [yY] ]]; then
          cdn_menu_nodes
        fi
      fi
      ;;
    2) cdn_menu_nodes ;;
    3)
      cdn_menu_uninstall || return 0
      ;;
    4 | q | Q)
      break
      ;;
    *)
      cdn_print_warn "无效选择：${choice}"
      ;;
    esac
  done
}

print_usage() {
  cat <<EOF
用法: cdn [命令]

命令:
  (无参数)          TTY 下进入交互菜单；非终端下同 install
  install           安装/更新 dae + cdnip geoip 数据库 + CDN 网段缓存并生成配置
  menu              交互菜单：安装 / 设置分流节点 / 全量卸载 / 退出
  update              强制重下 dae 二进制与 geoip 数据库 + CDN 网段缓存，然后重新 apply
  add <vless://…> [<trojan://…> …]   添加节点（vless/vmess/trojan/hysteria2/tuic/anytls），自动 apply
  add-sub <url> [标签]  添加订阅，自动 apply
  del <序号|关键字>     删除节点（按 cdn list 中的序号或链接关键字）
  del-sub <序号|关键字> 删除订阅
  list                列出节点/订阅（凭据掩码）与服务状态
  render              仅把配置渲染到 stdout（不写盘、不重启）
  apply               渲染并校验 config.dae，写盘后重启 dae
  restart|stop|start  控制 dae 服务
  status              查看 dae 服务状态
  log                 查看 dae 最近日志
  un                  全量卸载并清理
  -h|--help|help      显示本帮助

环境变量:
  node1..nodeN / sub1..subN    install 时预填节点/订阅
  cdn_policy          节点选择策略（默认 min）
  cdn_geoip_url / cdn_geoip_sha_url   自定义 geoip.dat 与校验地址
  cdn_skip_geo        跳过 geoip 下载（需自备 /usr/local/share/dae/geoip.dat）
  cdn_cdnip_base / cdn_cdnip_files    在线 CDN 网段清单地址与文件名（默认 jyucoeng/gcp_traffic_routing main）
  cdn_skip_cdnip      跳过 CDN 网段缓存（降级为仅 geoip 判定）
EOF
}

main() {
  local action="${1:-}"
  case "${action}" in
  "" )
    if [ -t 0 ]; then
      cdn_menu
    else
      cdn_install
    fi
    ;;
  install)
    cdn_install
    ;;
  update)
    cdn_update
    ;;
  add)
    shift
    cdn_add "$@"
    ;;
  add-sub)
    shift
    cdn_add_sub "$@"
    ;;
  del)
    shift
    cdn_del "$@"
    ;;
  del-sub)
    shift
    cdn_del_sub "$@"
    ;;
  list)
    cdn_list
    ;;
  render)
    cdn_render_config
    ;;
  apply)
    cdn_apply
    ;;
  restart | stop | start)
    cdn_service_ctl "${action}"
    ;;
  status)
    cdn_status
    ;;
  log)
    cdn_log
    ;;
  un)
    cdn_uninstall
    ;;
  -h | --help | help)
    print_usage
    exit 0
    ;;
  menu)
    cdn_menu
    ;;
  *)
    cdn_print_warn "未知命令：${action}"
    print_usage
    exit 1
    ;;
  esac
}

if [ "${CDN_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：CDN_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi