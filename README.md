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
`cdn.sh` 本身不含任何节点链接，节点仅存于数据文件 `/usr/local/etc/cdn-manager/nodes.txt`，
升级覆盖脚本也不影响，失效时随换随用。

以你常用的两种协议为例（**以下均为占位符，请把 `UUID`/`PASSWORD`/`IP`/`PORT` 换成你自己的真实值**）：

```bash
# ① vless + reality（xray 内核）
cdn add 'vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=公钥&sid=短ID&type=tcp&headerType=none'

# ② tuic（quic）
cdn add 'tuic://UUID:PASSWORD@IP:PORT?sni=目标站点&congestion_control=bbr&security=tls&udp_relay_mode=native&alpn=h3&allow_insecure=1'
```

每条 `cdn add` 会自动校验 → 写入 nodes.txt → 重新渲染 config.dae → 重启 dae。

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

> 订阅 URL 仍是**占位符**。本项目渲染的 `my_group` **不带 filter**，订阅拉下来的
> 节点和手动 `cdn add` 的节点都在同一个组里参与选路（`min` 探活 + 失效自动剔除）。

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
订阅 + 手动节点的**全量**都在 `my_group` 里，这是刻意的——避免你把流量
人为切分后失去「1 组 N 成员」的自动容灾。

## 组策略（my_group，建议保持默认）

> 所有 CDN 节点都在同一个组 `my_group` 里（不管加 1 个还是 3 个，
> 都是「1 组 N 成员」）。组策略决定 dae 在成员之间怎么选。
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

## 环境变量

| 变量 | 说明 |
|---|---|
| `node1..nodeN` | `install` 时预填节点链接 |
| `sub1..subN` | `install` 时预填订阅链接 |
| `cdn_policy` | `my_group` 节点选择策略（`min` 默认 / `random` / `min_avg10` / `min_moving_avg` / `fixed(0)`…） |
| `cdn_geoip_url` | 自定义 geoip.dat 下载地址（默认社区 cdnip 版） |
| `cdn_geoip_sha_url` | 自定义 sha256 校验文件地址（默认 `${cdn_geoip_url}.sha256sum`） |
| `cdn_skip_geo` | `1` 时跳过 geoip 下载（须已放置 `/usr/local/share/dae/geoip.dat`） |
| `cdn_cdnip_bundled_dir` | 随包离线 CDN 网段清单目录（默认 `/usr/local/share/dae/cdnip`，离线优先读取，GCP 断网也可用） |
| `cdn_cdnip_base` / `cdn_cdnip_files` | 本地随包清单缺失时回退在线拉取的地址与文件名（默认 `jyucoeng/gcp_traffic_routing` main） |
| `cdn_skip_cdnip` | `1` 时跳过 CDN 网段缓存（降级为仅 geoip 判定） |
| `cdn_force` | `1` 时强制重装（`cdn update` 内部使用） |
| `CDN_DAE_VERSION_URL` | 自定义 dae 版本查询接口（默认 GitHub API） |

## 离线说明

7 个 CDN 网段 txt（`1-cfcdn-ip-15.txt` ~ `5-akamai-ip-113.txt`）已**打包进发布包**，
`install.sh` 解包时自动落盘到 `/usr/local/share/dae/cdnip/`。`cdn install` / `cdn update`
**离线优先**读取本地随包清单生成 ipcidr 规则，即使 GCP 实例无法访问 GitHub 也能完整工作；
仅当本地清单缺失时才回退在线拉取。

## 前提

- GCP Debian/Ubuntu 实例（dae 需要 root + 完整内核，**容器内不支持**）
- 内核需开启 BTF（`CONFIG_DEBUG_INFO_BTF`），否则 eBPF 可能加载失败

## 开发与发布

```bash
scripts/build-release-bundle.sh   # 构建可复现 bundle 到 dist/
scripts/check-version.sh          # 版本一致性 + bundle 哈希门禁
tests/smoke.sh                    # 纯函数冒烟测试
tests/test-install.sh             # install.sh 函数级测试
```

bundle 为字节级可复现产物（`tar --format=gnu` + `gzip -n`），`install.sh` 内
`PACKAGE_SHA256` 与其严格一致。

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