# AMD 实例自动筛选脚本 (amd.sh) ---脚本里忘记添加了http-server/https-server的网络标记，所以需要你在运行amd.sh后，自行用实例管理命令添加这2个网络标记

自动创建 GCP VM 实例并筛选出 AMD CPU 平台的实例。

---

## 常用实例管理命令

### 查看实例的 tags

```bash
gcloud compute instances describe 实例名称 \
  --zone="实例对应的zone" \
  --project="你的项目ID" \
  --format="value(tags.items)"
```

### 给实例添加 http/https 网络标记（启用 Web 服务）

```bash
gcloud compute instances add-tags 实例名称 \
  --zone="实例对应的zone" \
  --project="你的项目ID" \
  --tags="http-server,https-server"
```

> **说明**：添加 `http-server` 和 `https-server` 网络标记后，GCP 会自动创建对应的防火墙规则，允许 HTTP(80) 和 HTTPS(443) 流量入站。

---

## 1. 安装 gcloud CLI

### macOS

```bash
# 下载安装
curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-x86_64.tar.gz -o gcloud.tar.gz
tar -xzf gcloud.tar.gz
./google-cloud-sdk/install.sh

# 添加到 PATH（添加到 ~/.zshrc 或 ~/.bashrc）
echo 'export PATH="$PATH:$HOME/google-cloud-sdk/bin"' >> ~/.zshrc
source ~/.zshrc
```

### Linux

```bash
curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o gcloud.tar.gz
tar -xzf gcloud.tar.gz
./google-cloud-sdk/install.sh

echo 'export PATH="$PATH:$HOME/google-cloud-sdk/bin"' >> ~/.bashrc
source ~/.bashrc
```

### 登录认证

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

---

## 2. 执行 amd.sh

```bash
# 赋予执行权限
chmod +x amd.sh

# 运行脚本
bash amd.sh
```

### 执行流程

```
启动 → 清理残留实例 → 等待配额释放
  ↓
并发创建2台实例
  ↓
并行检查CPU平台
  ↓
命中AMD → 保留该实例，删除其他 → 结束
  ↓
未命中 → 删除全部 → 等待删除完成 → 下一轮
```

### 日志文件

- 日志自动保存到 `logs/` 目录
- 文件名格式：`amd_20260901_171531.log`（带时间戳）
- 每次运行生成一个新日志文件

### 中途停止

按 `Ctrl+C` 可安全退出，脚本会自动清理所有实例。

---

## 3. amd.sh 可修改配置

### 必改配置

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PROJECT_ID` | GCP 项目 ID | `你的项目名称` |
| `ZONE` | 可用区 | `us-west1-a`（俄勒冈） |
| `INSTANCE_PREFIX` | 实例名称前缀 | `abc-gcp` |

### 可选配置

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MACHINE_TYPE` | 机器类型 | `e2-micro`（免费层级） |
| `IMAGE_FAMILY` | 系统镜像 | `debian-13` |
| `IMAGE_PROJECT` | 镜像项目 | `debian-cloud` |
| `DISK_SIZE` | 启动盘大小 | `30GB`（免费额度） |
| `DISK_TYPE` | 启动盘类型 | `pd-standard`（标准盘） |
| `NETWORK_TIER` | 网络层级 | `STANDARD`（免费层级） |
| `PROVISIONING_MODEL` | 预留模式 | `STANDARD`（非抢占式） |
| `TAGS` | 网络标签 | `nocdn` |
| `BATCH_SIZE` | 每轮并发创建数量 | `2` |
| `MAX_IPS` | 区域外部IP配额上限 | `4` |

### amd.sh需要修改配置的示例

```bash
# 修改项目ID和实例取名的前缀和区域
PROJECT_ID="你的项目名称"
INSTANCE_PREFIX="你的实例名称前缀，请用英文数字和字母"
ZONE="us-west1-c" # us-west1 代表俄勒冈，有 a/b/c三个机房编号，请自己修改，b区机器容易刷到amd

# 修改机器类型（注意：非e2-micro可能产生费用）
MACHINE_TYPE="e2-micro"

# 修改每轮并发数量（最大不超过MAX_IPS）
BATCH_SIZE=2
```

---

## 4. 注意事项

- **免费层级限制**：只保留 1 台 e2-micro 实例才免费
- **配额限制**：每个区域最多 4 个外部 IP
- **AMD 概率**：GCP 随机分配 CPU，AMD 命中率约 20-30%
- **费用风险**：脚本运行期间创建的实例即使被删除，也可能产生少量费用
- **封号风险**：高频创建/删除实例可能触发 GCP 风控，建议控制频率
