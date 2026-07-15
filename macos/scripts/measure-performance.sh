#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
用法：measure-performance.sh [选项]

采样已经运行的 Woo Todo App；脚本不会自行启动 GUI。

选项：
  --pid PID         直接指定进程 ID
  --bundle PATH     指定 .app 路径，默认 dist/Woo Todo.app
  --samples N       采样次数，默认 10
  --interval SEC    采样间隔秒数，默认 1
  --help             显示本帮助

可选环境变量：
  RSS_BUDGET_MB       平均 RSS 预算，默认 60 MB
  CPU_BUDGET_PERCENT  平均 CPU 预算，默认 0.3%
EOF
}

fail() {
    printf '错误：%s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少系统命令：$1"
}

TARGET_PID=""
BUNDLE_PATH=""
SAMPLES=10
INTERVAL=1
RSS_BUDGET_MB="${RSS_BUDGET_MB:-60}"
CPU_BUDGET_PERCENT="${CPU_BUDGET_PERCENT:-0.3}"

while (( $# > 0 )); do
    case "$1" in
        --pid)
            (( $# >= 2 )) || fail "--pid 缺少参数"
            TARGET_PID="$2"
            shift
            ;;
        --bundle)
            (( $# >= 2 )) || fail "--bundle 缺少参数"
            BUNDLE_PATH="$2"
            shift
            ;;
        --samples)
            (( $# >= 2 )) || fail "--samples 缺少参数"
            SAMPLES="$2"
            shift
            ;;
        --interval)
            (( $# >= 2 )) || fail "--interval 缺少参数"
            INTERVAL="$2"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1"
            ;;
    esac
    shift
done

[[ -z "$TARGET_PID" || "$TARGET_PID" =~ ^[1-9][0-9]*$ ]] || fail "PID 必须是正整数"
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || fail "采样次数必须是正整数"
[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "采样间隔必须是非负数字"
[[ "$RSS_BUDGET_MB" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "RSS 预算格式无效"
[[ "$CPU_BUDGET_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "CPU 预算格式无效"

require_command /bin/ps
require_command /bin/sleep
require_command /usr/bin/awk
require_command /usr/bin/pgrep

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
MACOS_DIR="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"
if [[ -z "$BUNDLE_PATH" ]]; then
    BUNDLE_PATH="$MACOS_DIR/dist/Woo Todo.app"
elif [[ "$BUNDLE_PATH" != /* ]]; then
    BUNDLE_PATH="$PWD/$BUNDLE_PATH"
fi

if [[ -d "$BUNDLE_PATH" ]]; then
    BUNDLE_PATH="$(cd -- "$BUNDLE_PATH" >/dev/null 2>&1 && pwd -P)"
fi
EXPECTED_EXECUTABLE="$BUNDLE_PATH/Contents/MacOS/woo-todo-mac"

if [[ -z "$TARGET_PID" ]]; then
    MATCHING_PIDS=()
    while IFS= read -r candidate; do
        [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || continue
        command_line="$(/bin/ps -p "$candidate" -o command= 2>/dev/null || true)"
        if [[ "$command_line" == "$EXPECTED_EXECUTABLE"* ]]; then
            MATCHING_PIDS+=("$candidate")
        fi
    done < <(/usr/bin/pgrep -x woo-todo-mac 2>/dev/null || true)

    if (( ${#MATCHING_PIDS[@]} == 0 )); then
        fail "没有找到正在运行的 bundle：$BUNDLE_PATH。请先手动启动 App。"
    fi
    if (( ${#MATCHING_PIDS[@]} > 1 )); then
        fail "找到多个匹配进程，请使用 --pid 明确指定"
    fi
    TARGET_PID="${MATCHING_PIDS[0]}"
fi

kill -0 "$TARGET_PID" 2>/dev/null || fail "进程不存在或无权访问：$TARGET_PID"
if ! COMMAND_LINE="$(/bin/ps -p "$TARGET_PID" -o command= 2>/dev/null)"; then
    fail "无法读取进程信息；请在普通终端中运行并确认有权访问 PID $TARGET_PID"
fi
if [[ "$COMMAND_LINE" != "$EXPECTED_EXECUTABLE"* ]]; then
    printf '提示：PID %s 的路径不是预期 bundle，将按指定 PID 继续采样。\n' "$TARGET_PID" >&2
    printf '实际命令：%s\n' "$COMMAND_LINE" >&2
fi

printf '开始采样 PID %s：共 %s 次，间隔 %s 秒。\n' "$TARGET_PID" "$SAMPLES" "$INTERVAL"
RSS_SUM_KB=0
RSS_MAX_KB=0
CPU_SUM=0

for (( index = 1; index <= SAMPLES; index += 1 )); do
    if ! sample="$(LC_ALL=C /bin/ps -p "$TARGET_PID" -o rss= -o %cpu=)"; then
        fail "采样期间进程已退出：$TARGET_PID"
    fi
    read -r rss_kb cpu_percent <<< "$sample"
    [[ "$rss_kb" =~ ^[0-9]+$ ]] || fail "无法解析 RSS 样本：$sample"
    [[ "$cpu_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "无法解析 CPU 样本：$sample"

    RSS_SUM_KB=$(( RSS_SUM_KB + rss_kb ))
    if (( rss_kb > RSS_MAX_KB )); then
        RSS_MAX_KB=$rss_kb
    fi
    CPU_SUM="$(/usr/bin/awk -v total="$CPU_SUM" -v value="$cpu_percent" \
        'BEGIN { printf "%.4f", total + value }')"
    rss_mb="$(/usr/bin/awk -v value="$rss_kb" \
        'BEGIN { printf "%.2f", value / 1024 }')"
    printf '样本 %02d/%02d：RSS %s MB，CPU %s%%\n' \
        "$index" "$SAMPLES" "$rss_mb" "$cpu_percent"

    if (( index < SAMPLES )); then
        /bin/sleep "$INTERVAL"
    fi
done

RSS_AVG_MB="$(/usr/bin/awk -v total="$RSS_SUM_KB" -v count="$SAMPLES" \
    'BEGIN { printf "%.2f", total / count / 1024 }')"
RSS_MAX_MB="$(/usr/bin/awk -v value="$RSS_MAX_KB" \
    'BEGIN { printf "%.2f", value / 1024 }')"
CPU_AVG="$(/usr/bin/awk -v total="$CPU_SUM" -v count="$SAMPLES" \
    'BEGIN { printf "%.3f", total / count }')"

printf '\n采样结果：平均 RSS %s MB，峰值 RSS %s MB，平均 CPU %s%%。\n' \
    "$RSS_AVG_MB" "$RSS_MAX_MB" "$CPU_AVG"

if /usr/bin/awk -v value="$RSS_AVG_MB" -v budget="$RSS_BUDGET_MB" \
    'BEGIN { exit !(value <= budget) }'; then
    printf 'RSS 预算通过：平均值不高于 %s MB。\n' "$RSS_BUDGET_MB"
else
    printf 'RSS 预算提示：平均值高于 %s MB，建议继续检查常驻对象。\n' "$RSS_BUDGET_MB"
fi

if /usr/bin/awk -v value="$CPU_AVG" -v budget="$CPU_BUDGET_PERCENT" \
    'BEGIN { exit !(value <= budget) }'; then
    printf 'CPU 预算通过：平均值不高于 %s%%。\n' "$CPU_BUDGET_PERCENT"
else
    printf 'CPU 预算提示：平均值高于 %s%%，建议检查定时器和刷新频率。\n' "$CPU_BUDGET_PERCENT"
fi
