#!/bin/bash
#
# BliKVM 2.x 视频启动脚本 —— 容器/通用 ARM 适配版
#
# 相对上游 lib/kvmd-video.sh 的改动：
#   1. 不再按 /proc/device-tree/model 白名单判断板型（Pi4/CM4/MangoPi），
#      改为探测 /dev/video* 并选第一个支持 MJPEG 的采集节点。
#   2. 默认不传 --resolution，按采集源原始分辨率直出，避免无谓缩放。
#      如确需缩放，设置环境变量 KVM_VIDEO_RESOLUTION=1280x720。
#   3. 编码器默认 CPU（MJPEG 软件编码）。Debian armhf 的 ustreamer 不含 x264，
#      若使用自编译带 x264 的版本，可设 KVM_VIDEO_ENCODER=LIBX264-VIDEO。
#   4. 采集设备可用 KVM_VIDEO_DEVICE 显式指定，跳过探测。
#
# 参数与上游保持一致：$0 <ustreamer_bin> <port> <fps> <quality> <kbps> <gop> <resolution>
#
# 本文件以 GPL-3.0 发布（与上游 blikvm-web-server 一致）。

set -u

if [ "$#" -ne 7 ]; then
    echo "Usage: $0 <ustreamer_bin> <port> <fps> <quality> <kbps> <gop> <resolution>"
    exit 1
fi

ustreamer_bin=$1
port=$2
fps=$3
quality=$4
kbps=$5
gop=$6
resolution=$7

# ---- 可覆盖的运行时配置 ----------------------------------------------------
# 采集设备：留空则自动探测
KVM_VIDEO_DEVICE="${KVM_VIDEO_DEVICE:-}"
# 编码器：CPU = MJPEG 软件编码；LIBX264-VIDEO 需要带 x264 的 ustreamer
KVM_VIDEO_ENCODER="${KVM_VIDEO_ENCODER:-CPU}"
# 输出分辨率：留空 = 按源分辨率直出
KVM_VIDEO_RESOLUTION="${KVM_VIDEO_RESOLUTION:-}"
# 采集格式：MJPEG 是最通用的 UVC 格式
KVM_VIDEO_FORMAT="${KVM_VIDEO_FORMAT:-MJPEG}"

ustreamer_pid=""

# 注意：log 必须写 stderr。pick_capture_device() 的返回值是靠 stdout 传的，
# 日志混进 stdout 会被 $(...) 当成设备名捕获。
log() { echo "[kvmd-video] $*" >&2; }

cleanup() {
    log "received signal $1, stopping ustreamer"
    [ -n "$ustreamer_pid" ] && kill "$ustreamer_pid" 2>/dev/null
    exit 0
}
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

# ---- 选择采集设备 ----------------------------------------------------------
# 优先用显式指定的设备；否则遍历 /dev/video*，挑第一个支持目标格式的。
# UVC 采集卡通常注册两个节点（采集 + 元数据），只挑真正能出流的那个。
pick_capture_device() {
    if [ -n "$KVM_VIDEO_DEVICE" ]; then
        if [ ! -c "$KVM_VIDEO_DEVICE" ]; then
            log "ERROR: KVM_VIDEO_DEVICE=$KVM_VIDEO_DEVICE 不存在或不是字符设备"
            return 1
        fi
        echo "$KVM_VIDEO_DEVICE"
        return 0
    fi

    for dev in /dev/video*; do
        [ -c "$dev" ] || continue
        # 没有 v4l2-ctl 时退化为「有节点就用」，但给出警告
        if ! command -v v4l2-ctl >/dev/null 2>&1; then
            log "WARN: 缺少 v4l2-ctl，无法校验采集格式，直接使用 $dev"
            echo "$dev"
            return 0
        fi
        if v4l2-ctl --list-formats-ext -d "$dev" 2>/dev/null | grep -qi "$KVM_VIDEO_FORMAT"; then
            echo "$dev"
            return 0
        fi
    done

    # 这里不打印错误：探测在等待循环里会重复调用，由循环统一输出一次提示
    return 1
}

# ---- 等待网络（保留上游行为，容器里通常很快满足）--------------------------
wait_network() {
    for _ in $(seq 1 30); do
        if ip link show lo 2>/dev/null | grep -q "UP"; then
            return 0
        fi
        sleep 1
    done
    log "WARN: 等待 lo 就绪超时，继续启动"
}

# ---- 主流程 ----------------------------------------------------------------
# 通用板传进来的是命令名（ustreamer），不是 ./lib/<board>/... 路径，
# 裸 [ -x ] 只在当前目录找，因此先用 command -v 解析成绝对路径
if [ ! -x "$ustreamer_bin" ]; then
    resolved=$(command -v "$ustreamer_bin" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
        ustreamer_bin=$resolved
    else
        log "ERROR: 找不到可执行的 ustreamer: $ustreamer_bin"
        exit 1
    fi
fi

wait_network

# 没有采集设备时不要退出：
#   - 容器内收不到 udev 热插拔事件，只能自己定时重试；
#   - 上游会把子进程的非零退出当成启动失败，reject 后直接终止整个服务。
# 因此这里等待设备出现，用户插入采集卡后自动开始出流。
attempt=0
while :; do
    if device=$(pick_capture_device); then
        break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -eq 1 ] || [ $((attempt % 6)) -eq 0 ]; then
        log "等待采集设备（已探测 $attempt 次，format=$KVM_VIDEO_FORMAT）；插入采集卡后自动开始出流"
    fi
    sleep 10
done
log "使用采集设备: $device (format=$KVM_VIDEO_FORMAT encoder=$KVM_VIDEO_ENCODER)"

# EDID 仅在 CSI 桥（TC358743 等）上可设置；UVC 采集卡通常不支持，失败不影响出流
if command -v v4l2-ctl >/dev/null 2>&1; then
    if [ -f "/mnt/exec/release/lib/edid.txt" ]; then
        v4l2-ctl --set-edid=file=/mnt/exec/release/lib/edid.txt --fix-edid-checksums 2>/dev/null \
            && log "EDID 已设置" || log "EDID 设置失败（UVC 采集卡属正常）"
    fi
fi

# 组装 ustreamer 参数
set -- "$ustreamer_bin" \
    --device="$device" \
    --host=0.0.0.0 \
    --port="$port" \
    --format="$KVM_VIDEO_FORMAT" \
    --encoder="$KVM_VIDEO_ENCODER" \
    --desired-fps="$fps" \
    --quality="$quality" \
    --drop-same-frames=30 \
    --persistent

# 只在显式要求时缩放；默认直出，保住文字清晰度
res="${KVM_VIDEO_RESOLUTION:-$resolution}"
if [ -n "$res" ] && [ "$res" != "native" ]; then
    set -- "$@" --resolution="$res"
    log "输出分辨率: $res（缩放）"
else
    log "输出分辨率: 源分辨率直出（不缩放）"
fi

# H.264 相关参数只在真正使用 H.264 编码器时才有意义
case "$KVM_VIDEO_ENCODER" in
    *X264*|*H264*|M2M-VIDEO)
        set -- "$@" --h264-bitrate="$kbps" --h264-gop="$gop"
        ;;
esac

log "启动: $*"
"$@" &
ustreamer_pid=$!

wait "$ustreamer_pid"
