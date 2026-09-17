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

## 安装

```bash
# 下载并安装管理器脚本（/usr/local/bin/cdn）
curl -fsSL https://github.com/jyucoeng/gcp_traffic_routing/releases/latest/download/install.sh | bash

# 同时初始化（安装 dae + cdnip geoip 数据库 + 生成配置并 apply）
# cdnt=1 curl -fsSL .../install.sh | bash
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
| `cdn install` | 安装/更新 dae + cdnip geoip 数据库，并生成配置 |
| `cdn update` | 强制重下 dae 二进制与 geoip 数据库后重新 apply |
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

## 环境变量

| 变量 | 说明 |
|---|---|
| `node1..nodeN` | `install` 时预填节点链接 |
| `sub1..subN` | `install` 时预填订阅链接 |
| `cdn_policy` | `my_group` 节点选择策略（`min` 默认 / `random` / `min_avg10` / `min_moving_avg` / `fixed(0)`…） |
| `cdn_geoip_url` | 自定义 geoip.dat 下载地址（默认社区 cdnip 版） |
| `cdn_geoip_sha_url` | 自定义 sha256 校验文件地址（默认 `${cdn_geoip_url}.sha256sum`） |
| `cdn_skip_geo` | `1` 时跳过 geoip 下载（须已放置 `/usr/local/share/dae/geoip.dat`） |
| `cdn_force` | `1` 时强制重装（`cdn update` 内部使用） |
| `CDN_DAE_VERSION_URL` | 自定义 dae 版本查询接口（默认 GitHub API） |

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