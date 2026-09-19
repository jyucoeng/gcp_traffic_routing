# netMonitor — 流量监控自动部署脚本

针对 **gcp / Oracle Cloud** 的 Linux 实例的流量监控与自动止损脚本。
通过监控网卡**上下行流量**（RX 入站 / TX 出站，分别统计、口径可配），超限后**全局封锁**（INPUT + OUTPUT + FORWARD 三条链跳转至自定义链，链内仅放行已建立连接 / SSH / DNS / ICMP / lo），并可选通过 TG 通知状态变化。
也支持其他指定平台（如 aws / azure / hetzner），仅需手动指定上限，见「二、可配置项」。

**完整支持纯 IPv4 / 纯 IPv6 / 双栈 VPS**：部署时自动探测地址族（`HAS_V4`/`HAS_V6`），封网与解网时按地址族分别操作 `iptables`(IPv4) 与 `ip6tables`(IPv6)；DNS 服务器按 IP 类型自动分流到对应表；纯 IPv6 机自动选用 IPv6 DNS 默认值。

**支持 Debian / Ubuntu / Alpine 三种系统**：`apt-get`+systemd、`apk`+OpenRC 自动识别，含 `iptables`/`ip6tables`、crontab/crond 一应俱全。流量统计由内置的 nezha 式脚本（读 `/proc/net/dev`）完成，**无 vnstat/守护进程依赖**。

---

## 一、脚本用途

单文件 `traffic_ctrl.sh`，TG 通知为**可选功能**，是否启用由部署时传入的环境变量决定：

| 部署方式 | 行为 |
|------|------|
| `PLATFORM=gcp LIMIT=180 bash traffic_ctrl.sh` | 纯封网版：超限封网 + 每月自动重置（**LIMIT 必须显式指定**，无平台默认值），不发任何通知 |
| `PLATFORM=oracle LIMIT=500 TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash traffic_ctrl.sh` | 同上，并额外在**断网时 / 网络恢复时**发送 Telegram 通知 |

两个 `TELEGRAM_*` 环境变量**均非空**才启用通知；任一为空即纯封网版。
`PLATFORM` 为平台标识（**大小写不敏感，含 `oracle`/`甲骨文` 即触发 oracle 逻辑**，可含中文如 `oracle首尔`，TG 标题原样显示），无需维护多套文件。

> **改配置统一通过子命令，勿手改配置文件。** 部署时全部参数固化到 **`/etc/traffic_routing/netMonitor.conf`**（权限 0600）。

> 之后调上限/端口/TG/日志保留天数，运行 **`bash /root/traffic_ctrl.sh edit`**（交互式菜单），改完自动加密落盘并即时生效（无需重新部署）。

> **⚠️ TG 凭据不明文落盘**：`TELEGRAM_BOT_TOKEN_ENC` / `TELEGRAM_CHAT_ID_ENC` 为 AES-256 加密密文（密钥存 `/etc/traffic_routing/netMonitor.key`，权限 0600）。换凭据请用子命令 `set-tg`，不要手改密文。

> **部署脚本建议下载到 VPS 本地保存**：封网后 VPS 断外网，但本地 `traffic_ctrl.sh` 仍可直接运行——可随时 `edit` 调配置、`set-tg` 换凭据、甚至**重新部署**（不依赖网络）。
>
> **快捷指令 `tfc`**：部署成功后自动把部署器落盘到 `SCRIPT_DIR/traffic_ctrl.sh`（默认 `/root/traffic_routing/traffic_ctrl.sh`），并在 `/usr/local/bin/tfc` 创建软链接指向它；之后 `tfc <子命令>` 与 `bash <落盘路径> <子命令>` 等价（如 `tfc config` / `tfc check` / `tfc restore` / `tfc edit`）。`bash <(curl …)` 进程替换部署时也会自动落盘，无需手动 `wget`；卸载时同步删除该链接。

---

## 二、可配置项（均为环境变量，未设置时取默认值）

| 环境变量 | 说明 | 默认 |
|------|------|------|
| `PLATFORM` | 平台标识（大小写不敏感，含 `oracle`/`甲骨文` 即触发 oracle 逻辑，可含中文如 `oracle首尔`）；其他任意标识（如 `aws`/`azure`/`hetzner`/`custom`）也可用，仅需手动指定 `LIMIT` | `gcp` |
| `LIMIT` | 流量上限（GB，支持小数如 `0.0002`≈0.2MB，**无默认值，部署必须显式指定**，留空直接报错；`0`/`-1` = 无限制，永不封网） | 无（必填） |
| `STAT_MODE` | **计费口径（超限判断用哪个方向流量）**：`in`=入站(下行)  `out`=出站(上行)  `min`=取小  `max`=取大  `sum`=总和（**所有平台统一默认 sum**）。超限判断 = 按此口径计得的当月字节 与 `LIMIT` 比较；可直接 `edit` 修改 | `sum`(总和) |
| `SSH_PORT` | 封网后仅放行的 SSH 管理端口。**填 VPS 内部 sshd 实际监听的端口**，与外部连接端口无关（见下方 NAT 机说明） | `22` |
| `DNS_SERVERS` | 封网后允许的 DNS 服务器，支持 IPv4/IPv6 混列；留空则按地址族自动选 | IPv4：`8.8.8.8 8.8.4.4`；纯 IPv6：`2001:4860:4860::8888 2001:4860:4860::8844` |
| `LOG_RETENTION_DAYS` | 流量监控日志保留天数：每月 1 号清理时只保留最近 N 天的日志行，删除更早的行 | `7`（`0`/`-1`=保留全部） |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot 的 token（`@BotFather` 创建） | 空（不启用通知） |
| `TELEGRAM_CHAT_ID` | 接收通知的 chat id | 空（不启用通知） |

```bash
# 1. 先下载部署脚本到本地保存（封网后断外网也能运行）
mkdir -p /root/traffic_routing && wget -O /root/traffic_routing/traffic_ctrl.sh https://raw.githubusercontent.com/jyucoeng/gcp_traffic_routing/main/netMonitor/traffic_ctrl.sh && chmod +x /root/traffic_routing/traffic_ctrl.sh && cd /root/traffic_routing

# 2. 纯封网版-没有tg通知（gcp 无默认上限，这里显式指定 180GB）
PLATFORM=gcp LIMIT=180 bash traffic_ctrl.sh

# 纯封网版，部署到 oracle，上限 500GB，SSH 端口 22（这个端口不要乱改，是内部22端口）
PLATFORM=oracle LIMIT=500 SSH_PORT=22 bash traffic_ctrl.sh

# 自定义平台示例：aws，手动指定上限 1024GB
PLATFORM=aws LIMIT=1024 bash /root/traffic_ctrl.sh

# TG 通知版，部署到 oracle（启用断网/恢复的tg通知）
PLATFORM=oracle LIMIT=500 TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash traffic_ctrl.sh

# TG 通知版，部署到 oracle首尔（平台名可含中文，含 oracle 即触发 oracle 逻辑，TG 标题显示对应平台名；小 LIMIT 用于测试断网/TG）
PLATFORM='oracle首尔' LIMIT=0.0002 STAT_MODE=sum \
TELEGRAM_BOT_TOKEN=xxx \
TELEGRAM_CHAT_ID=yyy \
bash traffic_ctrl.sh req
```

> 若 GitHub 无法访问，也可先用 `curl -O https://raw.githubusercontent.com/...` 下载。

`LIMIT` 说明（**无平台默认值，必须显式给出**）：

```
部署时不传 LIMIT     -> 直接报错退出（提醒你显式指定，避免误用平台推断的上限）
LIMIT=0 或 LIMIT=-1   -> 无限制：永不触发封网（仅统计展示，不做超限判定）
LIMIT=180            -> 上限 180GB
```

### TG 通知版注意事项

- 部署后改配置**统一通过子命令**，勿手改配置文件：`bash traffic_ctrl.sh edit`（交互式菜单）。
- **换 TG 凭据**：`TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy bash traffic_ctrl.sh set-tg`（AES-256 重新加密落盘，不影响其他配置）。
- **停用 TG**：`bash /traffic_ctrl.sh clear-tg`。
- **查看当前配置**：`bash traffic_ctrl.sh config`（密钥解密后以掩码显示，中间一半用 `*` 遮蔽）。
- **掩码算法**：`*` 数量 = 字符总数 / 2，首尾各保留剩余一半（即只暴露一半），过短(≤4位)则全隐藏。
- 未传 TG 环境变量仍会正常部署纯封网版（终端仅提示一次"通知未启用"）。

### oracle 平台额外行为（为什么需要停用 firewalld / ufw）

**ufw / firewalld 与 iptables 的关系：**
`ufw`（Ubuntu）和 `firewalld`（RHEL 系）是 iptables 的**前端管理工具**，不是替代品。它们最终都是操作 iptables/nftables 来管理防火墙规则。如果同时让它们和脚本直接操作 iptables，**规则会互相冲突覆盖**，导致封网失效。

本脚本的封网机制（自定义链 + 顶部跳转 + comment 精确删除）是 ufw/firewalld **无法表达的精细操作**，所以必须**直接操作 iptables**。为了让直接操作的 iptables 规则稳定生效，必须先停掉 ufw/firewalld，保证没有其他前端在接管 iptables。

**Oracle 实例的处理流程：**
```
Oracle 实例启动
    ↓
ufw / firewalld 默认开启（会接管/覆盖 iptables 规则）
    ↓
脚本先停掉它们（ufw disable / systemctl stop firewalld）→  使 iptables 处于干净状态
    ↓
脚本直接操作 iptables（封网/放行/解网）
```
- **部署时**：自动停用并禁用 firewalld / ufw。
- **每次 `check_traffic.sh` 运行时**：兜底检测一次，若发现被重新启用则再次停用（仅 `PLATFORM=oracle` 执行，gcp 跳过）。

仅停用，不做任何全局清空，不影响其他程序。gcp 默认镜像无这两个组件，不需要处理。

---

`PLATFORM` 对 TG 通知标题的影响：

| 特性 | `gcp` | `oracle` |
|------|-------|----------|
| 标题 | `🎮 gcp 流量报告` | `🎮 oracle 流量报告` |
| CPU 行 | 无 | `🧠 CPU: AMD/ARM` |
| 上限 | 需手动指定 `LIMIT` | 需手动指定 `LIMIT` |
| 额外行为 | 无 | 自动停用 firewalld / ufw |

---

## 三、部署与使用

### 1. 前置准备
- 以 **root** 身份执行（脚本开头会检查）。
- 用环境变量指定 `PLATFORM`；需要通知时再传 `TELEGRAM_BOT_TOKEN`、`TELEGRAM_CHAT_ID`。

### 2. 下载并执行部署
```bash
# 下载部署脚本到本地（建议永久保存，封网后可离线运行）
mkdir -p /root/traffic_routing && wget -O /root/traffic_routing/traffic_ctrl.sh https://raw.githubusercontent.com/jyucoeng/gcp_traffic_routing/main/netMonitor/traffic_ctrl.sh && chmod +x /root/traffic_routing/traffic_ctrl.sh && cd /root/traffic_routing

# TG 通知版（STAT_MODE 显式指定计费口径：in 入站 / out 出站 / max 取大 / min 取小 / sum 总和）
PLATFORM='oracle首尔' \
LIMIT=0.0002 STAT_MODE=sum \
TELEGRAM_BOT_TOKEN=xxx \
TELEGRAM_CHAT_ID=yyy \
bash traffic_ctrl.sh req
```

部署过程会：
0. 自动识别发行版（`debian`/`ubuntu`/`alpine`），分别用 apt 或 apk 装依赖
1. 自动探测默认网卡与地址族（先 IPv4 默认路由，失败回退 IPv6）
2. 安装依赖：`bc`、`curl`、`openssl`、`iptables`、`ip6tables`（aes 加密解密需要；恒装，后续启用 TG 无需重装依赖）
3. 生成独立流量统计脚本 `/root/traffic_routing/netstat.sh`（nezha 式：直接读 `/proc/net/dev`，排除虚拟网卡，**上下行分别统计**月度增量，不依赖 vnstat/守护进程）
4. 生成两个运行时脚本并写入 `/root/traffic_routing/`：
   - `/root/traffic_routing/check_traffic.sh` — 流量检查 & 封网
   - `/root/traffic_routing/reset_network.sh` — 每月重置
5. 配置 crontab / crond（自动去重）

### 3. 生成的定时任务（crontab）
| 计划 | 命令 | 说明 |
|------|------|------|
| 每 **5 分钟** (`*/5 * * * *`) | `/root/traffic_routing/check_traffic.sh` | 定时读取流量，超限即封网 |
| 每月 **1 号 00:00** (`0 0 1 * *`) | `/root/traffic_routing/reset_network.sh` | 每月重置流量、按保留天数清理日志、解除封网 |

> 即 `check_traffic.sh` 每 5 分钟执行一次；`reset_network.sh` 每月 1 号零点执行一次。如需调整频率，改部署脚本里对应的 crontab 行后重新部署。

### 3.5 流量统计原理（nezha 式，无守护进程）
上下行流量由独立脚本 `/root/traffic_routing/netstat.sh` 统计，算法与哪吒探针（nezha）一致，**上行(TX) 与下行(RX) 分开计数**：
1. 直接读 `/proc/net/dev`，**排除虚拟网卡**（lo / docker* / veth* / br-* / virbr* / tun* / tap* / vbox* / dummy*），对其余全部物理网卡分别对 **RX（入站字节，第 2 列）与 TX（出站字节，第 10 列）求和**作为当前累计值。
2. 通过「当前累计 − 上次快照」得到增量（上下行各自独立），分别累加到**当月累计**并持久化到 `/var/lib/traffic_monitor/netcount`。
3. 快照回绕检测：若当前累计 < 上次快照（服务器重启、计数器归零），则增量按「从 0 重新累计」，语义与 nezha 的 `min()` 防回绕一致，**重启不丢流量、不产生离谱负值**。
4. 跨月自动清零当月累计（新计费周期）；每月 1 号 `reset_network.sh` 额外执行 `netstat.sh --reset` 显式初始化。
5. 超限判断口径由 `STAT_MODE` 决定（`in`/`out`/`min`/`max`/`sum`），但上下行数据始终分别统计并在通知中展示。

因此统计**只关心网卡层上下行总量，不区分进程/IP**（与 nezha 一致），且不依赖 vnstat/任何守护进程。


### 4. 封网策略（全局封锁，仅影响本脚本，不干扰其他程序）
超限后，本脚本**只操作自己创建的 `TRAFFIC_BLOCKED` 链**，不改全局默认策略、不全局清空，**不影响其他程序已有的防火墙规则**。封网范围覆盖 **INPUT / OUTPUT / FORWARD 三条链**，实现真正全局封锁（**含转发至其他 VPS 的中转流量**，同样被 FORWARD 拦截）。**根据探测到的地址族**，IPv4 用 `iptables`、IPv6 用 `ip6tables`（含 `ip6tables` 专用的 `ipv6-icmp` 放行、IPv6 DNS 分流），双栈机两者同时生效。

封网时执行（以 IPv4 为例，IPv6 用 `ip6tables` 对应执行）：
```bash
# 创建/复用自家链 TRAFFIC_BLOCKED
iptables -N TRAFFIC_BLOCKED 2>/dev/null || iptables -F TRAFFIC_BLOCKED
# 链内放行：已建立连接、SSH、DNS、ICMP、loopback
iptables -A TRAFFIC_BLOCKED -m state --state ESTABLISHED,RELATED -j ACCEPT
# SSH 双向按方向匹配：INPUT 放行目标 dport（入站握手），OUTPUT 放行源 sport（SSH 回包）
iptables -A TRAFFIC_BLOCKED -p tcp --dport $SSH_PORT -j ACCEPT
iptables -A TRAFFIC_BLOCKED -p tcp --sport $SSH_PORT -j ACCEPT
iptables -A TRAFFIC_BLOCKED -p udp --dport 53 -d <DNS> -j ACCEPT   # 各 DNS 服务器(按地址族分别加入 iptables/ip6tables)
iptables -A TRAFFIC_BLOCKED -p tcp --dport 53 -d <DNS> -j ACCEPT   # DNS TCP 兜底（大响应/DoT 降级不断连）
iptables -A TRAFFIC_BLOCKED -p icmp -j ACCEPT                      # IPv6 用: -p ipv6-icmp
iptables -A TRAFFIC_BLOCKED -i lo -j ACCEPT
iptables -A TRAFFIC_BLOCKED -o lo -j ACCEPT
# 链内兜底 DROP：未放行的流量在本链终结，不回到主链
iptables -A TRAFFIC_BLOCKED -j DROP

# 在三条主链最顶部各插入一条跳转规则（存在则跳过，避免 cron 重复触发时堆积；旧版无此去重）
# 实际写法为 -C 检查存在则跳过、否则 -I 1 插入（此处为示意简写）
iptables -I INPUT   1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -I OUTPUT  1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -I FORWARD 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
```

**机制说明：**
- 放行：已建立连接（ESTABLISHED,RELATED）、SSH(`$SSH_PORT` 入/出双向)、DNS(`$DNS_SERVERS`，UDP+TCP 双协议)、ICMP(ping/IPv6 NDP)、loopback(入/出双向)。
- 其余未放行的出入站及转发流量，在 `TRAFFIC_BLOCKED` 链内被兜底 `DROP` 拦截 → 达到"全局封锁、仅留 SSH/DNS"效果。
- 因为跳转插在**最顶部**且链内兜底 DROP 是终结动作，其他程序（如程序 a）的 ACCEPT 规则会被本轮封网**覆盖**（但**未被删除**）。
- 默认策略（`-P`）、其他链的内容、其他程序规则全部保持不变。
- 封网规则带明显注释 `TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)`，一眼可识别是程序封网。

> **NAT 机 / 端口映射场景（Oracle、云 NAT、跳板等）**：`SSH_PORT` 一律填 **VPS 内部 sshd 实际监听的端口**，与外部连接端口无关。
> 例：外部 `ssh -p 39999 root@vps` 实际是某 NAT 把 `39999 → VPS 内部 22`，此时 `SSH_PORT` 应填 `22`（而不是 `39999`）。
> 原理：NAT 在 VPS 之外完成地址转换，**VPS 上看到的目标端口始终是 sshd 真实监听的端口**。脚本按该端口放行 INPUT（`--dport`）与 OUTPUT（`--sport`）即可保证封网后 SSH 不断。
> 反例：填外部端口（如 `39999`）会导致 VPS 内部无进程监听该端口，封网后入站 SSH 请求（目标 `22`）无法命中放行 → 自己锁死。

**恢复时只删除本脚本的三条跳转 + 自家链（解网=移除本脚本封锁，其他程序自然恢复）：**
```bash
iptables -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -F TRAFFIC_BLOCKED 2>/dev/null
iptables -X TRAFFIC_BLOCKED 2>/dev/null
```
删除后，其他程序的规则（如程序 a）**自然恢复生效**，无需任何额外处理。

### 5. 手动查看流量
```bash
bash /root/traffic_routing/check_traffic.sh
```
终端会显示上行(TX) / 下行(RX) 精确字节与格式化值、计费口径与计费流量；详情日志在 `/var/log/traffic_monitor.log`（每月 1 号只保留最近 `LOG_RETENTION_DAYS` 天，默认 7 天）。

### 6. 运行时配置文件 (`/etc/traffic_routing/netMonitor.conf`)
部署时生成，权限 `0600`，各字段（仅作展示，**改配置请用子命令，勿手改**）：
```
PLATFORM="oracle首尔"                    # 平台（大小写不敏感，可含中文，TG 标题原样显示）
LIMIT=500                               # 流量上限 GB（0/-1=无限制）
STAT_MODE=sum                           # 计费口径 out/in/min/max/sum
SSH_PORT=2222                           # SSH 管理端口
DNS_SERVERS="8.8.8.8 8.8.4.4"           # 放行的 DNS
HAS_V4=1                                # IPv4 是否可达（部署时探测）
HAS_V6=0                                # IPv6 是否可达
LOG_RETENTION_DAYS=7                    # 日志保留天数（0/-1=保留全部）
INTERFACE="ens4"                        # 监控网卡（自动探测）
AUTHOR="littleDoraemon"                 # 作者署名（部署期常量）
VERSION="v0.1.0"                        # 版本号（部署期常量）
TELEGRAM_BOT_TOKEN_ENC="U2FsdGVkX1..."  # AES-256 密文（勿手改，用 set-tg）
TELEGRAM_CHAT_ID_ENC="U2FsdGVkX1..."    # AES-256 密文（勿手改，用 set-tg）
```
- 修改任何配置统一用 `bash traffic_ctrl.sh edit`（交互式菜单），改完自动加密落盘、即时生效；
- 换 TG 凭据也可用 `set-tg`（会重新加密），停用用 `clear-tg`，查看用 `config`（掩码显示）；
- 密钥文件 `/etc/traffic_routing/netMonitor.key`（0600）丢失后密文**不可恢复**，需重新 `set-tg`。

### 7. 子命令一览
| 子命令 | 作用 |
|------|------|
| `req` / `install` | 部署 / 覆盖安装（装完停住，按任意键进菜单） |
| `menu`（或无参数） | 进入管理菜单（安装/查看/修改/TG/流量/恢复/卸载/退出） |
| `edit` | 交互式菜单修改平台/上限/口径/SSH端口/DNS/TG/日志保留天数（推荐） |
| `config` | 查看当前配置，凭据掩码显示（中间一半用 `*` 遮蔽） |
| `set-tg` | 更换 TG 凭据（`TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... bash traffic_ctrl.sh set-tg`） |
| `clear-tg` | 停用通知并清除凭据 |
| `check` | 查看流量（跑 `check_traffic.sh`：查当月上下行 + 超限判定 + 封网） |
| `restore` | 恢复网络（跑 `reset_network.sh`：清封网 + 重置统计 + 归档） |
| `del` / `un` | 卸载（清本脚本封网规则 + 删 crontab 调度/运行时脚本/conf/state/notify/日志；**保留密钥 key 与月度档案 archive、流量累计 netcount**） |
| `help` | 显示全部命令用法 |

---

## 四、TG 通知与状态机制（启用 TG 时）

> **核心规则：** 整个通知机制按**每月周期**运作。每个计费月内，超限通知和恢复通知各**最多发送一次**。

### 通知时机
| 时机 | 标题 | 触发条件 | 频率 |
|------|------|---------|------|
| 超限断网前 | `🎮 {PLATFORM} 流量报告（流量超限通知）` | 当月首次流量 ≥ LIMIT，封网前发送 | 当月首次超限时发送 **1 次** |
| 每月 1 号恢复 | `🎮 {PLATFORM} 流量报告（网络恢复通知）` | 当月曾处于断网状态，reset 恢复后发送 | 每月 1 号最多发送 **1 次** |

### 通知内容（模板，与当前代码一致）
超限通知：
```
🎮 oracle首尔 流量报告（流量超限通知）

🌐 本机IP: 152.70.235.27 (Seoul-KR)
🕐 运行时间: 2026-09-19 10:00:00
📚 网络状态: 正常 ---> 超限(双向封网)
📊 计费口径: sum-总和 / 上限: 0.0002 GB (0.20MB)
🌐 已用流量: 13.71MB / (上行 6.09MB / 下行 7.61MB)
🌐 CPU: ARM        ← 仅 oracle 显示
```
恢复通知：
```
🎮 oracle首尔 流量报告（网络恢复通知）

🌐 本机IP: 152.70.235.27 (Seoul-KR)
🕐 运行时间: 2026-10-01 00:00:02
📚 网络状态: 超限封网 ---> 已恢复
📊 计费口径: sum-总和 / 上限: 500 GB
🌐 已用流量: 0.00MB / (上行 0.00MB / 下行 0.00MB)
📊 上月计费口径: sum-总和 / 上限: 500 GB
🌐 上月已用流量: 143.55GB / (上行 123.45GB / 下行 20.10GB) (重置前耗尽，仅有数据时显示)
🌐 CPU: ARM        ← 仅 oracle 显示
```
- **口径中文名**：`sum-总和` / `out-出站` / `in-入站` / `max-取大` / `min-取小`；上月口径优先用封网当时落盘的 `USED_STAT_MODE`（月中改口径不影响上月显示），缺失回退当前口径
- **上限换算**：上限恒显示 `X GB`，与已用流量单位不同时括号追加换算值（如 `0.0002 GB (0.20MB)`）；已用为 GB 时不加括号
- **本机IP**：多来源探测链 `ip-api.com` → `ipwho.is` → `ipify`，全部失败回退本机网卡地址；**当前不打码，原样显示**。城市/国家取 `ip-api.com`（重试 3 次，失败降级仅显示国家 → `unknown`）
- **流量**：按层级自动换算 `MB → GB → TB`（<1GB 用 MB；<1024GB 用 GB；≥1024GB 用 TB），小数补前导 0（如 `0.65MB`）
- **运行时间**：北京时间（`TZ='UTC-8'` = UTC+8）
- **CPU**（仅 oracle）：`aarch64`→ARM；型号含 `AMD`/`EPYC`→AMD
- **恢复通知**：只有上月确实超限封过网（`STATE=blocked`）且 TG 启用才发；上月两行仅有数据时显示；本月恒为 0（刚 reset 清零）

### 状态文件与发送历史（保证"每月各最多 1 条"）
状态记录在 `/var/lib/traffic_monitor/state`：
```
MONTH=2026-10        # 当前跟踪月份
STATE=normal         # normal / blocked
BLOCKED_TIME=""      # 本月断网时刻（已恢复则保留上次值）
BLOCKED_TX=""        # 断网时已用计费流量(字节, 按 STAT_MODE 口径，即 BAL_BYTES)
RESTORED_TIME=""     # 恢复时刻
USED_STAT_MODE=sum   # 最近一次判定用的口径/上限/上下行/计费流量（当月快照）
USED_LIMIT=500
USED_TX=0
USED_RX=0
USED_BAL=0
```
TG 发送历史记录在 `/var/lib/traffic_monitor/notify`（一行一月，UTC 时间戳）：
```
2026-08 OVER=2026-08-19T02:00:00Z RESTORE=2026-09-01T00:00:05Z
2026-09 OVER=2026-09-19T03:40:10Z RESTORE=-
```
- `USED_*` 为**当月流量快照**：每次 check 判定后落盘；每月 reset 清零本月累计后随之归零（上月的最终值归档到 `/var/lib/traffic_monitor/archive`，一行一月）。
- `notify` 与 `state` 分离存放：删 `state` / 覆盖重装 / 流量回落后同月再超限，都**不重发**（判定只看 `notify`，封网本身每次照常执行）。测试时想重发，手动删文件：`rm -f /var/lib/traffic_monitor/notify`。
- `notify` 只保留最近 12 个月（每次发送时自动裁剪）；`RESTORE=-` 表示当月恢复通知尚未发送（次月 1 号 reset 发送后才写入）。
- 每月 reset 恢复后，若上月确实断过网且 TG 启用，才发恢复通知，并进入新月份周期。

---

## 五、封网确认与手动解锁 / 恢复

### 1. 如何确认当前是否处于封网状态

超限封网后现象：**SSH 正常（22 端口放行），但 `wget`/`curl` 外网失败**（如 `wget` 报 `unable to resolve host` / `failed: Try again`），这是符合预期的断网效果，不是 VPS 故障。

```bash
iptables -L INPUT -n | grep -c TRAFFIC_BLOCKED   # 1=封着，0=正常（双栈机再查 ip6tables 同一条）
cat /var/lib/traffic_monitor/state | grep STATE  # blocked=封着，normal=正常
```

### 2. 解封（推荐用 reset 脚本）

每月 1 号 `reset_network.sh` 会自动恢复。手动立即解封首选直接跑 reset 脚本（清防火墙 + 重置统计 + 写 archive，TG 恢复通知按规则发送）：

```bash
bash /root/traffic_routing/reset_network.sh
# 验证：跳转条数归 0，外网恢复 200
iptables -L INPUT -n | grep -c TRAFFIC_BLOCKED
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://www.google.com
```

### 3. 解封（备用：手动删规则，只删本脚本的规则，不影响其他程序）

reset 脚本不可用时才用。下面以 IPv4 为例，**纯 IPv6 机把 `iptables` 换成 `ip6tables` 执行；双栈机两者都执行**：
```bash
iptables -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D INPUT    -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D OUTPUT   -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D FORWARD  -j TRAFFIC_BLOCKED 2>/dev/null
iptables -F TRAFFIC_BLOCKED
iptables -X TRAFFIC_BLOCKED
```

---

## 六、文件清单与说明

### 仓库内文件

| 文件 | 说明 |
|------|------|
| `netMonitor/traffic_ctrl.sh` | 单文件部署脚本（纯封网版 / TG 通知版由部署时传入的环境变量决定） |
| `readme-net.md` | 本文档 |

### 部署后生成的文件（VPS 上）

| 文件 | 说明 |
|------|------|
| `/root/traffic_ctrl.sh`（或自选路径如 `/root/traffic_routing/traffic_ctrl.sh`，以实际运行的那份为准） | 部署脚本本地副本（封网后断外网仍可运行 edit / set-tg 或重新部署） |
| `/root/traffic_routing/check_traffic.sh` | 运行时监控脚本（每 5 分钟 cron 执行：查流量、超限封网、TG 通知） |
| `/root/traffic_routing/reset_network.sh` | 运行时重置脚本（每月 1 号 cron 执行：清理日志、清封网规则、重置统计、归档、TG 恢复通知） |
| `/root/traffic_routing/netstat.sh` | 流量统计脚本（nezha 式 /proc/net/dev + 月度增量，无 vnstat 依赖） |
| `/etc/traffic_routing/netMonitor.conf` | 运行时配置（0600，PLATFORM/LIMIT/STAT_MODE/SSH_PORT/DNS/网卡/日志保留/加密凭据；改配置请用子命令，勿手改） |
| `/etc/traffic_routing/netMonitor.key` | TG 凭据 AES-256 加密密钥文件（0600，仅 root 可读；**丢失后凭据不可恢复**，需重新 `set-tg`） |
| `/var/log/traffic_monitor.log` | 监控日志（每月 1 号按 `LOG_RETENTION_DAYS` 保留最近 N 天，默认 7 天） |
| `/var/log/network_reset.log` | 重置日志 |
| `/var/lib/traffic_monitor/state` | 运行状态（当前月/封网状态/断网恢复时刻/当月流量快照 USED_*；卸载时删除） |
| `/var/lib/traffic_monitor/notify` | TG 发送历史（一行一月 UTC 时间戳，`OVER` 超限 / `RESTORE` 恢复；每月各最多 1 条的判定依据；只留最近 12 个月；**卸载时清空**，覆盖重装保留） |
| `/var/lib/traffic_monitor/netcount` | 流量月度累计（MONTH + 当月上行/下行字节，由 netstat.sh 持久化；**卸载与覆盖安装均保留**） |
| `/var/lib/traffic_monitor/archive` | 月度流量档案（每月重置前把上月最终 TX/RX 追加一行，长期留存；含 `mode=` 上月口径与 `blocked=` 封网状态；卸载保留） |
| `/var/lib/traffic_monitor/grand_total` | 总计流量（从部署到现在的上下行总计，长期累计，卸载不清） |
| `/var/lib/traffic_monitor/netcount_YYYY-MM` | 月度快照（每月 reset 时归档 netcount，只留最近 12 个月） |
