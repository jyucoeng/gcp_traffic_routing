# gcp_traffic_routing 使用指南（部署 / 节点 / 验证）

> 适用版本：v1.0.0（dae v2.1.1）
> 本文档记录在 VPS 上完成「部署 → 添加节点 → 分流验证」的完整流程与命令，
> 均已在 Debian 13（KVM x86_64）实测通过。

---

## 一、部署步骤

### 1.1 官方一键安装（推荐）

```bash
curl -fsSL https://github.com/jyucoeng/gcp_traffic_routing/releases/latest/download/install.sh | bash
```

install.sh 自动完成：下载发布包 → SHA256 校验（与 `PACKAGE_SHA256` 比对）→
安装 `cdn` 脚本到 `/usr/local/bin/cdn` → 随包 7 个 CDN 网段清单落盘到
`/usr/local/share/dae/cdnip/`。

> 想一条命令完成安装 + 初始化：`cdnt=1 bash install.sh`

### 1.2 手动部署（离线 / 自定义路径）

```bash
# 上传：cdn.sh + 7 个清单 txt（1-cfcdn-ip-15.txt ~ 5-akamai-ip-113.txt）+ VERSION
install -m 0755 cdn.sh /usr/local/bin/cdn
install -m 0644 1-*.txt 2-*.txt 3-*.txt 4-*.txt 5-*.txt /usr/local/share/dae/cdnip/
```

### 1.3 初始化（安装 dae + geoip + CDN 缓存 + 生成配置）

```bash
cdn install
```

预期输出（关键行）：

```text
[OK] dae v2.1.1（x86_64_v3_avx2）安装完成：/usr/local/bin/dae
[OK] geoip.dat（cdnip 标签）已安装：/usr/local/share/dae/geoip.dat
[OK] CDN 网段清单已缓存（475 条）：/usr/local/share/dae/cdnip.txt
[OK] 配置已写入：/usr/local/etc/dae/config.dae
```

---

## 二、添加 / 更换节点

### 2.1 新机器一条龙（安装 + 加节点一步到位）

```bash
cdn install \
  'vless://UUID@IP:端口?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=公钥&sid=短id&type=tcp&headerType=none' \
  'tuic://UUID:密码@IP:端口?sni=www.apple.com&congestion_control=bbr&security=tls&udp_relay_mode=native&alpn=h3&allow_insecure=1'
```

### 2.2 已装好，追加/删除节点（自动 apply + 重启，无需手动 apply）

```bash
cdn add '<节点链接>' ...        # 追加节点（vless/vmess/trojan/hysteria2/tuic/anytls）
cdn list                        # 查看掩码后的节点与序号
cdn del 2                       # 按序号删除
cdn del '<关键字>'              # 按关键字删除（数字关键字：序号优先，无匹配回退关键字）
```

### 2.3 订阅

```bash
cdn add-sub '<订阅URL>' [标签]
cdn list
cdn del-sub '<序号|标签>'
```

---

## 三、分流验证

### 3.1 一键自测（在 VPS 上执行）

```bash
curl -4 -sS https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=; \
curl -4 -sS -o /dev/null -w 'fastly:%{http_code}\n' https://www.fastly.com/; \
curl -4 -sS -o /dev/null -w 'akamai:%{http_code}\n' https://www.akamai.com/; \
curl -4 -sS https://ipinfo.io/ip; echo
```

**预期结果**（以本文档实测 VPS 161.33.136.001 为例）：

```text
ip=192.9.158.88      ← CDN 出口 = 节点 IP（非本机）
fastly:200           ← Fastly 访问成功
akamai:403           ← Akamai 反爬拦截（流量已走通，属正常）
161.33.136.001       ← 非 CDN 出口 = VPS 本机公网 IP
```

### 3.2 四路分流对照

| 类型 | 站点 | URL | 预期 |
|---|---|---|---|
| CDN | Cloudflare | `https://www.cloudflare.com/cdn-cgi/trace` | `ip=` 为节点 IP |
| CDN | Fastly | `https://www.fastly.com/` | HTTP 200 |
| CDN | Akamai | `https://www.akamai.com/` | HTTP 200/403（403 为反爬，属正常） |
| 非 CDN | ipinfo.io | `https://ipinfo.io/ip` | 返回 VPS 本机公网 IP |

> 其他可测 CDN 站点：`https://www.jsdelivr.com/`（Cloudflare）、`https://www.cdn77.com/`（CDN77）。

### 3.3 日志佐证（统一日志文件 `/var/log/dae/dae.log`）

```bash
# 查看最近分流明细（命中 CDN 缓存 / geoip 的连接）
grep -E "outbound=cdn_(cache|geoip)_group" /var/log/dae/dae.log | tail -n 10

# 只查某个域名
grep "sniffed=www.cloudflare.com" /var/log/dae/dae.log | tail -n 5

# 实时跟踪（边访问边看）
tail -f /var/log/dae/dae.log | grep -E "outbound=cdn_(cache|geoip)_group"
```

**日志字段含义**（dae debug 级每连接一行）：

```text
DEBUG 10.0.11.111:46980 <-> www.cloudflare.com:443 dialer=小叮当-…-vless… 
      ip=104.16.124.96:443 outbound=cdn_cache_group pname=curl sniffed=www.cloudflare.com
```

| 字段 | 含义 |
|---|---|
| `<-> www.cloudflare.com:443` | 本次访问的目标（域名+端口） |
| `sniffed=` | TLS 嗅探出的域名（同 `dst` 域） |
| `outbound=cdn_cache_group` | **命中本地 CDN 网段缓存**（首层规则）→ 走节点 |
| `outbound=cdn_geoip_group` | 缓存未命中、**geoip:cdnip 命中**（第二层）→ 走节点 |
| `dialer=小叮当-…-tuic/vless…` | 实际使用的节点 |
| 无 `outbound=cdn_*` 记录 | 直连（`fallback: direct`，非 CDN 流量） |

### 3.4 日志中的 DNS 佐证

非 CDN 站点只出现 DNS 行、无连接转发行，即为直连：

```text
DEBUG cache hit _qname=ipinfo.io. dest=169.254.169.254:53 … qtype=A …
```

---

## 四、常用运维

| 命令 | 说明 |
|---|---|
| `cdn status` | 服务状态 + 配置 + 日志路径 |
| `cdn log` | 查看最近 50 行日志（读统一日志文件） |
| `cdn render` | 仅渲染配置到 stdout（不写盘） |
| `cdn apply` | 重新渲染校验并写盘、重启服务 |
| `cdn restart\|stop\|start` | 控制服务 |
| `cdn update` | 强制重下 dae/geoip + 重建 CDN 缓存并重新 apply |
| `cdn un` | 全量卸载（服务/二进制/geoip/配置/节点/缓存） |

关键文件路径：

```text
/usr/local/bin/cdn               # 管理器脚本（v1.0.0）
/usr/local/bin/dae               # dae 二进制
/usr/local/etc/dae/config.dae    # 渲染后的配置
/usr/local/etc/cdn-manager/nodes.list   # 节点清单
/usr/local/etc/cdn-manager/subs.list    # 订阅清单
/usr/local/share/dae/cdnip.txt   # CDN 网段缓存（475 条）
/usr/local/share/dae/geoip.dat   # cdnip geoip 数据库
/var/log/dae/dae.log             # 统一日志（dae --logfile，30MB×3 轮转）
```

## 五、实测记录（v1.0.0 @ Debian 13 VPS）

```text
部署: cdn un（卸载 0.1.2）→ 上传 v1.0.0 → cdn install → cdn add 双节点
服务: dae v2.1.1 (systemd) active + enabled
节点: [1] tuic://#cd2747@192.9.158.88:31005
      [2] vless://#56a01b@192.9.158.88:31003

四路验证:
  Cloudflare → ip=192.9.158.88（节点）   outbound=cdn_cache_group ✅
  Fastly     → http 200                  outbound=cdn_cache_group ✅
  Akamai     → http 403（反爬）          outbound=cdn_cache_group ✅
  ipinfo.io  → 161.33.136.001（本机直连） 无 outbound=cdn_* ✅
```