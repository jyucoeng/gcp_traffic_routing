# gcp_traffic_routing

GCP 免费实例出站 CDN 流量分流管理器（独立项目，自包含单脚本）。

## 背景

GCP 对出站到部分 CDN 网段（Cloudflare / Fastly / Akamai 等，geodata 中的 `cdnip` 标签）
单独计费且很贵。本项目在本机安装 [dae](https://github.com/daeuniverse/dae)（eBPF 透明代理），
按"目的 IP 是否命中 `cdnip` 网段"分流：

- 命中 CDN 网段 → 走你提供的 vless/vmess/trojan/hysteria2/tuic/anytls 节点（免费/便宜节点）中转
- 其余流量 → 直接连接

从而避开 GCP 对本机到 CDN 出站的高额计费。

> 本项目与 Singbox Manager 无任何关系，也不依赖它；`cdn.sh` 自包含。

## 添加 / 更换目标节点（核心用法）

要转发到的节点由你自己在 VPS 上通过 `cdn add` 提供，**不写死在脚本里**——
`cdn.sh` 本身不含任何节点链接，节点仅存于数据文件 `/usr/local/etc/cdn-manager/nodes.list`，
升级覆盖脚本也不影响，失效时随换随用。

以你常用的两种协议为例（**以下均为占位符，请把 `UUID`/`PASSWORD`/`IP`/`PORT` 换成你自己的真实值**）：

```bash
# ① vless + reality（xray 内核）
cdn add 'vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=公钥&sid=短ID&type=tcp&headerType=none'

# ② tuic（quic）
cdn add 'tuic://UUID:PASSWORD@IP:PORT?sni=目标站点&congestion_control=bbr&security=tls&udp_relay_mode=native&alpn=h3&allow_insecure=1'
```

每条 `cdn add` 会自动校验 → 写入 nodes.list → 重新渲染 config.dae → 重启 dae。

节点失效后的更换流程：

```bash
cdn list               # 查看掩码后的节点与序号
cdn del <序号或关键字>   # 删掉失效节点（自动 apply）
cdn add '<新节点链接>'   # 加入新节点（自动 apply）
```

> 订阅一把提供的场景：`cdn add-sub '<订阅URL>' 标签`，换节点只改远端，本地零维护。

## 安装

```bash
# 一条命令完成：下载 install.sh -> /usr/local/bin/cdn/（目录不存在则自动创建并赋权）
# -> 给 install.sh 加执行权限 -> 切换到该目录并执行
mkdir -p /usr/local/bin/cdn \
  && curl -fsSL https://github.com/jyucoeng/gcp_traffic_routing/releases/latest/download/install.sh -o /usr/local/bin/cdn/install.sh \
  && chmod 0755 /usr/local/bin/cdn \
  && chmod +x /usr/local/bin/cdn/install.sh \
  && cd /usr/local/bin/cdn \


  bash  install.sh
```

安装后初始化亦可手动执行（此时文件已在上一步落盘）：

```bash
cd /usr/local/bin/cdn && ./install.sh
```

安装后初始化亦可手动执行：

```bash
cdn            # 安装 dae + geoip + 配置（需 root）
```

## 命令

| 命令 | 说明 |
|---|---|
| `cdn` | TTY 下进入交互菜单（1 安装 / 2 设置分流节点 / 3 全量卸载 / 4 退出）；非终端下同 `install` |
| `cdn menu` | 显示交互菜单 |
| `cdn install` | 安装/更新 dae + cdnip geoip 数据库 + 随包 CDN 网段缓存，并生成配置 |
| `cdn update` | 强制重下 dae 二进制与 geoip 数据库，重建 CDN 网段缓存后重新 apply |
| `cdn add <链接...>` | 添加节点（`vless://` `vmess://` `trojan://` `hysteria2://` `tuic://` `anytls://`），自动 apply |
| `cdn add-sub <url> [标签]` | 添加订阅，自动 apply |
| `cdn del <序号\|关键字>` | 删除节点，自动 apply |
| `cdn del-sub <序号\|关键字>` | 删除订阅，自动 apply |
| `cdn list` | 列出节点/订阅（凭据掩码）与服务状态 |
| `cdn render` | 仅渲染配置到 stdout（不写盘） |
| `cdn apply` | 渲染、校验并写盘 config.dae，重启服务 |
| `cdn restart\|stop\|start` | 控制 dae 服务 |
| `cdn status` | 查看 dae 服务状态 |
| `cdn log` | 查看 dae 最近日志 |
| `cdn un` | 全量卸载并清理 |

## 加节点 / 换节点全流程（一条命令，占位示例）

> 以下 `UUID`、`密码`、`IP`、`端口` 均为**占位符**，换成你自己的真实值即可。
> 脚本本身不内置任何节点；无实例可用时换节点永远是一条命令 + 自动重启，不用重装。

**新机器一条龙（install 时顺手把第一个节点也加了）**

```bash
# 安装 dae + CDN 网段清单，并把第一对节点直接落进去（等价于 install 后再 add，但只敲一次）
cdn install \
  'vless://UUID@IP:端口?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=公钥&sid=短id&type=tcp&headerType=none' \
  'tuic://UUID:密码@IP:端口?sni=www.apple.com&congestion_control=bbr&security=tls&udp_relay_mode=native&alpn=h3&allow_insecure=1'
```

**已有服务，只想加/换节点（`add` / `del` 都自动 apply+重启，不用敲 `cdn apply`）**

```bash
cdn add 'vless://UUID@IP:端口?…'                    # 追加第二个节点
cdn del 2                                           # 删除刚加的（按序号）
cdn list                                            # 掩码查看剩余节点与序号
```

**失效换新（一条 `del` + 一条 `add`，均自动重启 dae）**

```bash
cdn del 上一篇或用关键字
cdn add 'vless://UUID@新IP:端口?…'
```

## 订阅 demo（占位 URL，换节点只改远端）

> 订阅 URL 仍是**占位符**。本项目渲染的分流组（`cdn_cache_group` /
> `cdn_geoip_group`）**不带 filter**，订阅拉下来的节点和手动 `cdn add` 的节点
> 都同时进入两个组参与选路（`min` 探活 + 失效自动剔除）。

```bash
# 加订阅（可带标签；标签仅字母数字 _ -）
cdn add-sub 'https://订阅地址/xxx' main
cdn add-sub 'https://另一个订阅地址/yyy'

# 看订阅（地址已掩码，序号/标签可见）
cdn list
# == 订阅 ==
#   [1] main -> https://订阅地址/…
#   [2] sub_2 -> https://另一个订阅地址/…

# 删订阅（序号或关键字或标签），自动 apply + 重启
cdn del-sub 2          # 按序号
cdn del-sub main       # 按标签/关键字
```

订阅对应的渲染段（`cdn render` 可见）：

```dae
subscription {
    main: 'https://订阅地址/xxx'
    sub_2: 'https://另一个订阅地址/yyy'
}
```

要不要锁死某订阅进特定组（subtag filter）：本项目当前不渲染 `filter`，
订阅 + 手动节点的**全量**都进入两个分流组（`cdn_cache_group` / `cdn_geoip_group`），
这是刻意的——避免你把流量人为切分后失去「N 节点自动容灾」。

## 分流组（cdn_cache_group / cdn_geoip_group）

> 脚本渲染**两个分流组**，共享同一节点池（`node`/`subscription` 段的所有节点）：
>
> - `cdn_cache_group` —— 命中本地 CDN 网段缓存（`dip('cidr',...)` 首层规则）
> - `cdn_geoip_group` —— 未命中缓存、命中 `geoip.dat` 的 `cdnip` 标签
>
> 两组策略一致（默认 `min`），拆分仅为了让**日志里 `outbound=` 字段一眼可辨
> 流量是"命中 CDN 缓存"还是"命中 geoip"**，并分别显示所用节点（`dialer=`）。
>
> **建议：保持默认 `min`，不做任何配置。** 只有当节点间反复横跳
> （流量在 2~3 个节点来回抖动）时，才考虑切 `min_moving_avg`。

| 策略 | 行为 | 适用 |
|---|---|---|
| `min`（默认） | 组内持续探活，走**实时 RTT 最低**的节点；失效节点自动从候选池剔除 | 日常（失效自动转移） |
| `random` | 组内随机选一个 | 不追最低时延，想摊开 |
| `min_avg10` | 走**近 10 次平均 RTT 最低**的节点 | 网络抖动大、不想被单次毛刺带走 |
| `min_moving_avg` | 走**移动平均最低**的节点（最稳） | 节点间反复横跳时用 |
| `fixed(0)` | 钉死组内第 0 个节点，**不探活不自动切换** | 明确要固定走主节点（放弃自动转移） |

切换方式（环境变量，`install` / `update` / `apply` 前导出）：

```bash
export cdn_policy='min_moving_avg'
cdn apply
```

## 分流日志（默认开启，统一一个文件）

`cdn log` 直接读取 **统一日志文件** `/var/log/dae/dae.log`（dae 服务以
`--logfile` 写入，自动轮转 30MB×3），`log_level` 默认 `debug`，**每个连接
都有一条明细**，形如：

```text
DEBUG 10.0.11.111:36196 <-> 198.41.192.7:7844 dialer=小叮当-…-vless-reality-SJE1Y4K … outbound=cdn_cache_group pname=cloudflared …
DEBUG 2603:c021:…:41614 <-> www.cloudflare.com:443 dialer=小叮当-…-tuic-SJE1Y4K … outbound=cdn_geoip_group pname=curl sniffed=www.cloudflare.com
```

含义：**访问 `www.cloudflare.com:443` → `outbound=cdn_cache_group`
（命中 CDN 缓存）→ `dialer=…-tuic-SJE1Y4K`（实际走的 tuic 节点）**。
`outbound=cdn_geoip_group` 表示命中 geoip:cdnip；`outbound=direct` 表示直连。

可用 `cdn_log_level` 调低级别（如 `info`）减少输出，日志文件路径用
`DAE_LOG_FILE` 覆盖；`cdn status` 也会显示当前日志文件位置。

## 分流验证（一键自测）

### 一键命令（在 VPS 上执行）

同时访问三大 CDN 站点 + 一个非 CDN 站点，直接对比出口 IP：

```bash
curl -4 -sS https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=; \
curl -4 -sS -o /dev/null -w 'fastly:%{http_code}\n' https://www.fastly.com/; \
curl -4 -sS -o /dev/null -w 'akamai:%{http_code}\n' https://www.akamai.com/; \
curl -4 -sS https://ipinfo.io/ip; echo
```

预期结果（CDN 走节点、非 CDN 直连本机）：

```text
ip=192.9.158.37      ← CDN 出口 = 你的节点 IP
fastly:200           ← Fastly 访问成功
akamai:403           ← Akamai 反爬拦截（流量已走通，属正常）
161.33.136.221       ← 非 CDN 出口 = VPS 本机 IP
```

### 测试站点对照表

| 类型 | 站点 | URL | 预期 |
|---|---|---|---|
| CDN | Cloudflare | `https://www.cloudflare.com/cdn-cgi/trace` | `ip=` 为节点 IP |
| CDN | Fastly | `https://www.fastly.com/` | HTTP 200 |
| CDN | Akamai | `https://www.akamai.com/` | HTTP 200/403（403 为反爬，属正常） |
| 非 CDN | ipinfo.io | `https://ipinfo.io/ip` | 返回 VPS 本机公网 IP |

> 也可换其他 CDN 域名测试：`https://www.jsdelivr.com/`（Cloudflare）、
> `https://www.cdn77.com/`（CDN77）等。

### 结合日志核对

访问上述站点后，在 VPS 上抓取对应分流明细佐证：

```bash
grep -E "outbound=cdn_(cache|geoip)_group" /var/log/dae/dae.log | tail -n 10
# 只查某个域名：grep "sniffed=www.cloudflare.com" /var/log/dae/dae.log
# 实时跟踪：tail -f /var/log/dae/dae.log | grep -E "outbound=cdn_(cache|geoip)_group"
```

CDN 流量应出现 `outbound=cdn_cache_group … dialer=节点名`（缓存命中）或
`outbound=cdn_geoip_group …`（geoip 命中）；非 CDN 流量无 `outbound=cdn_*` 记录，
即 `fallback: direct` 直连。

## 环境变量

| 变量 | 说明 |
|---|---|
| `node1..nodeN` | `install` 时预填节点链接 |
| `sub1..subN` | `install` 时预填订阅链接 |
| `cdn_policy` | 分流组节点选择策略（`min` 默认 / `random` / `min_avg10` / `min_moving_avg` / `fixed(0)`…，`cdn_cache_group`/`cdn_geoip_group` 共用） |
| `cdn_log_level` | dae 日志级别（默认 `debug`，输出每连接"访问目标 + 所用节点"分流明细） |
| `DAE_LOG_FILE` | 统一日志文件路径（默认 `/var/log/dae/dae.log`，服务以 `--logfile` 写入，`cdn log` 读取） |
| `cdn_geoip_url` | 自定义 geoip.dat 下载地址（默认社区 cdnip 版） |
| `cdn_geoip_sha_url` | 自定义 sha256 校验文件地址（默认 `${cdn_geoip_url}.sha256sum`） |
| `cdn_skip_geo` | `1` 时跳过 geoip 下载（须已放置 `/usr/local/share/dae/geoip.dat`） |
| `cdn_cdnip_bundled_dir` | 随包离线 CDN 网段清单目录（默认 `/usr/local/share/dae/cdnip`，离线优先读取，GCP 断网也可用） |
| `cdn_cdnip_base` / `cdn_cdnip_files` | 本地随包清单缺失时回退在线拉取的地址与文件名（默认 `jyucoeng/gcp_traffic_routing` main） |
| `cdn_skip_cdnip` | `1` 时跳过 CDN 网段缓存（降级为仅 geoip 判定） |
| `cdn_force` | `1` 时强制重装（`cdn update` 内部使用） |
| `CDN_DAE_VERSION_URL` | 自定义 dae 版本查询接口（默认 GitHub API） |
| `cdnt` | `install.sh` 专用：设为任意非空值即安装后自动初始化（等价于再执行一次 `cdn`，内部调 `cdn install`） |

## 离线说明

7 个 CDN 网段 txt（`1-cfcdn-ip-15.txt` ~ `5-akamai-ip-113.txt`）已**打包进发布包**，
`install.sh` 解包时自动落盘到 `/usr/local/share/dae/cdnip/`。`cdn install` / `cdn update`
**离线优先**读取本地随包清单生成 `dip(CIDR,...)` 规则，即使 GCP 实例无法访问 GitHub 也能完整工作；
仅当本地清单缺失时才回退在线拉取。

## 前提

- GCP Debian/Ubuntu 实例（dae 需要 root + 完整内核）
- 内核需开启 BTF（`CONFIG_DEBUG_INFO_BTF`），否则 eBPF 可能加载失败

### 容器环境不支持（重要）

dae 是 eBPF 透明代理，运行依赖内核的 `bpf()` 系统调用。**LXC / Docker / Podman /
OpenVZ / systemd-nspawn 等容器环境不支持运行 dae**，原因：

- 容器内 `bpf()` 系统调用通常被宿主禁止（返回 `EPERM`），eBPF 程序与 map 均无法创建；
- dae 启动时会尝试提升 `RLIMIT_MEMLOCK`，容器内同样会被拒绝，
  实测报错：`FATAL rlimit.RemoveMemlock: failed to set memlock rlimit: operation not permitted`；
- 即使容器共享宿主内核并持有全部 capability，eBPF 能力仍由宿主控制，容器内无法获取。

`cdn install` 会在安装前通过 `cdn_check_container` 检测运行环境：优先使用
`systemd-detect-virt`；无该命令时（如 Alpine）回退读取 `/proc/1/environ` 的
`container=` 标记（LXC 容器 PID 1 环境含 `container=lxc`）。命中容器白名单
（openvz / lxc / docker / podman / ...）即拒绝安装并提示：

```text
[ERROR] 检测到容器运行时（lxc），dae（eBPF 透明代理）不支持容器内安装：容器内 bpf() 系统调用通常被禁，eBPF 无法加载。请改用 KVM/裸机 VPS。
```

> 实测：Alpine 3.22 LXC 容器内，安装步骤（dae 二进制 / geoip / 配置）均可正常完成，
> 但 dae 服务启动即崩溃（bpf 被禁）。请使用 KVM/裸机 VPS（如 GCP 计算引擎实例）。

## 开发与发布

```bash
scripts/build-release-bundle.sh   # 构建可复现 bundle 到 dist/
scripts/check-version.sh          # 版本一致性 + bundle 哈希门禁
tests/smoke.sh                    # 纯函数冒烟测试
tests/test-install.sh             # install.sh 函数级测试
```

bundle 为字节级可复现产物（`tar --format=gnu` + `gzip -n`），`install.sh` 内
`PACKAGE_SHA256` 与其严格一致。

## 上线清单（发布前逐项核对）

发布新版本时按以下顺序执行，全部 ✅ 才可发 Release：

| # | 检查项 | 命令/位置 | 通过标准 |
|---|---|---|---|
| 1 | 版本号三处一致 | `VERSION` / `cdn.sh` 的 `SCRIPT_VERSION` / `install.sh` 的 `PROJECT_VERSION` | 三者统一为 `vX.Y.Z` |
| 2 | 语法检查 | `bash -n` 全部脚本 | 无报错 |
| 3 | 功能冒烟 | `bash tests/smoke.sh` | 全部 ✅ 通过 |
| 4 | 安装流程测试 | `bash tests/test-install.sh` | 全部 ✅ 通过 |
| 5 | 构建 bundle | `bash scripts/build-release-bundle.sh` | 产出 `dist/<仓库名>-vX.Y.Z.tar.gz` |
| 6 | 回填 SHA | 把 `cat dist/checksums.txt` 的哈希写回 `install.sh` 的 `PACKAGE_SHA256` | 与 bundle 一致 |
| 7 | 最终门禁 | `bash scripts/check-version.sh` | 10/10 ✅ 全绿 |
| 8 | 提交推送 | `git add … && git commit && git push origin main` | 远端 main 为最新 |
| 9 | 打 tag | `git tag vX.Y.Z && git push origin vX.Y.Z` | 远端出现该 tag |
| 10 | 建 Release | GitHub Releases 页新建（或编辑已有 tag） | 见下方「部署说明」 |
| 11 | 上传资产 | 上传两个文件到 Release | 见下方「部署说明」 |
| 12 | 线上可下载 | `curl -sIL <PACKAGE_URL>` 返回 200 | 资产生效（刚上传偶有 CDN 延迟） |

> 版本号升级只需改三处：`VERSION`（去 `v` 前缀后须与 `cdn.sh` 字面量相等）、
> `cdn.sh` 顶部 `SCRIPT_VERSION="X.Y.Z"`、`install.sh` 顶部 `PROJECT_VERSION="vX.Y.Z"`。
> 其余脚本自动读取，无需手改。

## 部署说明（新机器 / 升级）

### 方式一：官方一键安装（推荐，含 bundle SHA256 校验）

```bash
curl -fsSL https://github.com/jyucoeng/gcp_traffic_routing/releases/latest/download/install.sh | bash
```

install.sh 会自动：下载发布包 → SHA256 校验（与 `PACKAGE_SHA256` 比对）→
安装 `cdn` 到 `/usr/local/bin/cdn` → 随包 CDN 网段清单落盘到
`/usr/local/share/dae/cdnip/`。装完后再初始化：

```bash
cdn install                     # 安装 dae + geoip.dat + 生成配置
cdn add '<tuic/vless 节点链接>'  # 添加分流节点（自动 apply 生效）
```

> 想一条命令完成安装 + 初始化：`cdnt=1 bash install.sh`（install.sh 装完后自动跑 `cdn install`）。

### 方式二：手动部署（离线 / 自定义路径）

```bash
# 1. 上传源码文件到目标机（cdn.sh + 7 个 CDN 网段 txt + VERSION）
# 2. 落盘
install -m 0755 cdn.sh /usr/local/bin/cdn
install -m 0644 *.txt /usr/local/share/dae/cdnip/
# 3. 初始化
cdn install
cdn add '<tuic://…>' '<vless://…>'
```

### 部署后验收（必须看到分流生效）

```bash
# ① 服务状态
cdn status                       # dae active，两组 + 日志路径正常

# ② 四路分流实测（CDN 走节点 / 非 CDN 直连本机）
curl -4 -sS https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=; \
curl -4 -sS -o /dev/null -w 'fastly:%{http_code}\n' https://www.fastly.com/; \
curl -4 -sS -o /dev/null -w 'akamai:%{http_code}\n' https://www.akamai.com/; \
curl -4 -sS https://ipinfo.io/ip; echo

# ③ 日志佐证
grep -E "outbound=cdn_(cache|geoip)_group" /var/log/dae/dae.log | tail
```

预期：CDN 站点出口 = 节点 IP（非本机），非 CDN 出口 = 本机公网 IP，
日志出现 `outbound=cdn_cache_group … dialer=节点名` 行。

### 升级已有部署

```bash
cdn update    # 强制重下 dae 二进制 + geoip + 重建 CDN 缓存并重新 apply
# 或先卸载再装：cdn un && 按上面「方式一/二」重新部署
```

### 卸载

```bash
cdn un        # 删除 dae 服务/二进制/geoip/配置/节点/CDN 缓存（保留 cdn 脚本）
# 交互菜单里选 3 全量卸载则连 cdn 脚本一并删除
```

## Fork 并弄成你自己的项目

项目采用**单一事实源**设计：所有仓库/项目标识都从 `install.sh` 顶部常量派生，
Fork 后绝大部分情况只需改 `install.sh` 一处。

### 一、改你的标识（必需）

打开 `install.sh` 顶部（约第 6-12 行）：

```bash
REPO_OWNER="jyucoeng"             # 改成你自己的 GitHub 用户名
REPO_NAME="gcp_traffic_routing"   # 改成你的仓库名（保持与仓库 URL 一致）
```

其余脚本（`build-release-bundle.sh` / `check-version.sh`）会自动 `source` 该文件读取，
无需手动改。版本号在 `VERSION` 文件与 `install.sh` 的 `PROJECT_VERSION`（两者须一致）。

可选：想改菜单显示名，编辑 `cdn.sh` 顶部 `PROJECT_NAME`（不影响发布包命名）。

### 二、迭代开发验证（本地）

```bash
bash tests/smoke.sh               # cdn.sh 功能
bash tests/test-install.sh        # install.sh 功能
bash scripts/check-version.sh     # 版本/语法门禁（此时 SHA 为空，报缺 SHA 属预期）
```

### 三、发布（GNU tar 环境，如 Debian/Ubuntu）

```bash
bash scripts/build-release-bundle.sh   # 产出 dist/<仓库名>-<版本>.tar.gz 与 checksums.txt
cat dist/checksums.txt                 # 拿到 64 位 sha256
```

把该哈希填回 `install.sh` 顶部：

```bash
PACKAGE_SHA256="<64位哈希>"
```

再次验证全绿：

```bash
bash scripts/check-version.sh     # 应全部 ✅
```

### 四、建 GitHub Release 并发布

1. 把 `install.sh`（含已回填哈希）提交推送到你的仓库；
2. 在 GitHub `Releases` 页面新建 tag `v<版本>`（如 `v0.1.0`），
   标题写版本号；
3. 上传两个资产文件：
   - `dist/<仓库名>-<版本>.tar.gz`
   - `install.sh`
4. 发布。

> 资产名必须与 `PACKAGE_NAME` 完全一致（`<仓库名>-<版本>.tar.gz`），
> 因为 `install.sh` 用同名 URL 下载。

### 五、用户侧一条命令安装

仓库首页的 `README.md` 安装命令会自动指向你的 repo/Release（安装 URL 用
`${REPO_OWNER}/${REPO_NAME}` 构造），无需改动作。

```bash
curl -fsSL https://github.com/<你的用户名>/<你的仓库名>/releases/latest/download/install.sh | bash
```

如需把示例里的仓库名也替换掉，可搜索并替换 `README.md` 中残留的
`jyucoeng/gcp_traffic_routing`。