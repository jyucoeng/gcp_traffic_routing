#!/bin/bash

# 只需要修改这里的4-6行的3个变量的值，其他的不要改
PROJECT_ID="你的项目名称"
INSTANCE_PREFIX="你的实例名称前缀，请用英文数字和字母"
ZONE="us-west1-c" # us-west1 代表俄勒冈，有 a/b/c三个机房编号，请自己修改，b区机器容易刷到amd

MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="debian-13"
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="30GB"
DISK_TYPE="pd-standard"
NETWORK_TIER="STANDARD"
PROVISIONING_MODEL="STANDARD"
TAGS="nocdn"

BATCH_SIZE=2
MAX_IPS=4                  # 区域外部IP配额上限

# --- 日志文件 ---
LOG_DIR="$(dirname "$0")/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/amd_$(date '+%Y%m%d_%H%M%S').log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

log "📝 日志文件: $LOG_FILE"

# --- 清理函数 ---
cleanup() {
  log ""
  log "🛑 收到中断信号，开始清理所有 $INSTANCE_PREFIX-* 实例..."
  INSTANCES_TO_DELETE=$(gcloud compute instances list \
    --filter="name~${INSTANCE_PREFIX}-" \
    --zones="$ZONE" \
    --project="$PROJECT_ID" \
    --format="value(name)" 2>/dev/null)

  if [ -n "$INSTANCES_TO_DELETE" ]; then
    for inst in $INSTANCES_TO_DELETE; do
      log "  🗑️ 正在删除: $inst"
      gcloud compute instances delete "$inst" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --quiet &
    done
    wait
    log "✅ 所有实例已清理完毕。"
  else
    log "✅ 没有需要清理的实例。"
  fi
  exit 0
}

trap cleanup SIGINT SIGTERM

# --- 等待所有实例删除完毕 ---
wait_all_deleted() {
  while true; do
    REMAINING=$(gcloud compute instances list \
      --filter="name~${INSTANCE_PREFIX}-" \
      --zones="$ZONE" \
      --project="$PROJECT_ID" \
      --format="value(name)" 2>/dev/null)
    if [ -z "$REMAINING" ]; then
      break
    fi
    REMAINING_COUNT=$(echo "$REMAINING" | wc -l | tr -d ' ')
    log "⏳ 还有 ${REMAINING_COUNT} 个实例未删除，等待 5 秒..."
    sleep 5
  done
}

# --- 启动前清理残留实例 ---
log "🔍 检查是否有上次残留的实例..."
EXISTING=$(gcloud compute instances list \
  --filter="name~${INSTANCE_PREFIX}-" \
  --zones="$ZONE" \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null)

if [ -n "$EXISTING" ]; then
  log "⚠️ 发现残留实例，正在清理..."
  for inst in $EXISTING; do
    log "  🗑️ 正在删除: $inst"
    gcloud compute instances delete "$inst" \
      --zone="$ZONE" \
      --project="$PROJECT_ID" \
      --quiet &
  done
  wait
  wait_all_deleted
  log "✅ 残留实例已清理。"
else
  log "✅ 没有残留实例。"
fi

# --- 主逻辑 ---
log "🚀 开始批量创建并筛选 AMD 实例 (每轮 $BATCH_SIZE 台, 配额 $MAX_IPS IP)..."

COUNTER=1
CREATED_TOTAL=0
START_TIME=$(date +%s)

while true; do
  # 1. 确保所有实例已删除（配额检查）
  wait_all_deleted

  ROUND=$(( (COUNTER - 1) / BATCH_SIZE + 1 ))
  log "========================================"
  log "🔁 第 ${ROUND} 轮 | 创建实例: $(( COUNTER )) ~ $(( COUNTER + BATCH_SIZE - 1 ))"

  # 2. 并发创建 BATCH_SIZE 台实例
  PIDS=()
  NAMES=()
  for i in $(seq 0 $((BATCH_SIZE - 1))); do
    INSTANCE_NAME="${INSTANCE_PREFIX}-$((COUNTER + i))"
    NAMES+=("$INSTANCE_NAME")
    log "  🛠️ 正在创建: $INSTANCE_NAME"
    gcloud compute instances create "$INSTANCE_NAME" \
      --zone="$ZONE" \
      --project="$PROJECT_ID" \
      --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$DISK_SIZE" \
      --boot-disk-type="$DISK_TYPE" \
      --network-tier="$NETWORK_TIER" \
      --provisioning-model="$PROVISIONING_MODEL" \
      --tags="$TAGS" \
      --metadata=enable-osconfig=false \
      --quiet &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
  CREATED_TOTAL=$((CREATED_TOTAL + BATCH_SIZE))

  # 3. 并行检查 CPU 平台
  FOUND_TARGET=""
  TMPDIR_CHECK=$(mktemp -d)
  CHECK_PIDS=()

  for INSTANCE_NAME in "${NAMES[@]}"; do
    (
      CPU_PLATFORM=$(gcloud compute instances describe "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --format='value(cpuPlatform)' 2>/dev/null)
      echo "$CPU_PLATFORM" > "${TMPDIR_CHECK}/${INSTANCE_NAME}"
    ) &
    CHECK_PIDS+=($!)
  done

  for pid in "${CHECK_PIDS[@]}"; do
    wait "$pid"
  done

  for INSTANCE_NAME in "${NAMES[@]}"; do
    CPU_PLATFORM=$(cat "${TMPDIR_CHECK}/${INSTANCE_NAME}" 2>/dev/null)
    if [[ "$CPU_PLATFORM" == *"AMD"* ]]; then
      log "  🔍 $INSTANCE_NAME → ✅✅✅ 🎉 AMD 命中！✅✅✅"
      FOUND_TARGET="$INSTANCE_NAME"
      break
    else
      log "  🔍 $INSTANCE_NAME → 🚫 $CPU_PLATFORM"
    fi
  done
  rm -rf "$TMPDIR_CHECK"

  # 4. 处理结果
  if [[ -n "$FOUND_TARGET" ]]; then
    log "========================================"
    log "🎉 成功命中 AMD 实例！"
    log "✅ 保留实例: $FOUND_TARGET"
    log "🗑️ 清理其他实例..."

    for INSTANCE_NAME in "${NAMES[@]}"; do
      if [[ "$INSTANCE_NAME" != "$FOUND_TARGET" ]]; then
        log "  🗑️ 正在删除: $INSTANCE_NAME"
        gcloud compute instances delete "$INSTANCE_NAME" \
          --zone="$ZONE" \
          --project="$PROJECT_ID" \
          --quiet &
      fi
    done
    wait

    TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
    log "📊 总耗时: $((TOTAL_ELAPSED / 3600))时$((TOTAL_ELAPSED % 3600 / 60))分$((TOTAL_ELAPSED % 60))秒 | 共创建: $CREATED_TOTAL 台"
    log "🎯 任务完成！"
    break
  else
    log "🚫 本轮未命中 AMD，删除全部实例..."

    for INSTANCE_NAME in "${NAMES[@]}"; do
      log "  🗑️ 删除: $INSTANCE_NAME"
      gcloud compute instances delete "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --quiet 2>/dev/null &
    done
    wait
    log "✅ 本轮实例已全部删除。"
  fi

  COUNTER=$((COUNTER + BATCH_SIZE))
  ELAPSED=$(( $(date +%s) - START_TIME ))
  WAIT_TIME=$(( RANDOM % 10 + 5 ))
  NEXT_TIME=$(date -v +${WAIT_TIME}S '+%H:%M:%S' 2>/dev/null || date -d "+${WAIT_TIME} seconds" '+%H:%M:%S' 2>/dev/null)
  log "⏳ 已耗时: $((ELAPSED / 3600))时$((ELAPSED % 3600 / 60))分$((ELAPSED % 60))秒 | 等待 ${WAIT_TIME} 秒，下一轮约 ${NEXT_TIME} 开始..."
  sleep $WAIT_TIME
done
