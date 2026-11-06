#!/bin/bash
#
# BliKVM 2.x 容器入口
#
# 职责：
#   1. 校验宿主机是否满足特权容器的硬性前提（UDC / configfs / 采集设备）
#   2. 准备容器内运行目录与持久化目录
#   3. 在缺少原生 Node 模块时给出明确警告而不是静默失败
#   4. 前台拉起 BliKVM 服务并转发信号
#
# 本文件以 GPL-3.0 发布（与上游 blikvm-web-server 一致）。

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/blikvm}"
CONFIG_DIR="${CONFIG_DIR:-/data/config}"

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. 环境自检
# ---------------------------------------------------------------------------
log "BliKVM 2.x 容器启动"

arch=$(uname -m)
case "$arch" in
    armv7l|aarch64|armv8l) log "架构: $arch" ;;
    *) warn "架构 $arch 非 ARM，容器可能无法运行上游二进制（本方案仅支持 ARM）" ;;
esac

# USB gadget 控制器：HID / MSD 功能的硬性前提
if [ -z "$(ls -A /sys/class/udc 2>/dev/null || true)" ]; then
    warn "未检测到 USB Device/OTG 控制器（/sys/class/udc 为空）"
    warn "  → 键鼠（HID）与虚拟介质（MSD）将不可用"
    warn "  → 需要宿主内核启用 USB gadget 并配置 dr_mode=otg/peripheral"
    HID_OK=0
else
    log "USB 控制器: $(ls /sys/class/udc | tr '\n' ' ')"
    HID_OK=1
fi

# configfs：gadget 配置的前提
if ! grep -qs configfs /proc/filesystems; then
    warn "内核不支持 configfs，HID/MSD 不可用"
    HID_OK=0
elif ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    log "挂载 configfs"
    mount -t configfs none /sys/kernel/config 2>/dev/null || warn "configfs 挂载失败"
fi

# 采集设备：视频功能的前提
if ! ls /dev/video* >/dev/null 2>&1; then
    warn "未检测到 /dev/video* 采集设备，视频功能不可用"
    warn "  → 请确认 USB 采集卡已插入，且宿主已加载 uvcvideo"
    VIDEO_OK=0
else
    log "采集设备: $(ls /dev/video* | tr '\n' ' ')"
    VIDEO_OK=1
fi

# 至少有一项核心功能可用，否则启动没有意义
if [ "${HID_OK:-0}" -eq 0 ] && [ "${VIDEO_OK:-0}" -eq 0 ]; then
    die "既无 USB gadget 也无采集设备，容器无法提供任何 KVM 功能。请检查 --privileged 与设备直通。"
fi

# ---------------------------------------------------------------------------
# 2. 运行目录准备
# ---------------------------------------------------------------------------
log "准备运行目录"
mkdir -p \
    /mnt/tmp/logs \
    /mnt/tmp/record \
    /mnt/msd/user \
    /mnt/msd/config \
    /mnt/msd/ventoy \
    /media/blikvm/ventoy \
    /dev/shm/blikvm \
    /var/blikvm

# 配置持久化：首次启动时从镜像内默认配置复制到挂载卷
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/app.json" ]; then
    log "初始化配置到 $CONFIG_DIR"
    cp "$APP_DIR/config/"*.json "$CONFIG_DIR/" 2>/dev/null || warn "默认配置复制失败"
fi

# msd 状态文件
if [ ! -f /mnt/msd/config/msd.json ]; then
    echo '{"msd_status": "not_connected","msd_img_created": "not_created"}' > /mnt/msd/config/msd.json
fi

# ---------------------------------------------------------------------------
# 3. 原生模块检查（缺失时给出可操作的提示，而不是崩溃栈）
# ---------------------------------------------------------------------------
cd "$APP_DIR"
missing=""
for m in serialport i2c-bus bcrypt evdev; do
    if [ ! -d "node_modules/$m" ] && [ ! -d "/usr/lib/nodejs/$m" ]; then
        missing="$missing $m"
    fi
done
if [ -n "$missing" ]; then
    warn "缺少原生 Node 模块:$missing"
    warn "  → 串口 / EEPROM 读板型 / 账号密码哈希 相关功能可能不可用"
    warn "  → 账号功能依赖 bcrypt，缺失将导致无法登录，请务必补齐"
fi

# ---------------------------------------------------------------------------
# 4. 启动服务
# ---------------------------------------------------------------------------
# 上游入口：node src/index.js <app.json> <switch.json> <wol.json> <acl.json> <shortcuts.json>
CONFIG_ARGS=(
    "$CONFIG_DIR/app.json"
    "$CONFIG_DIR/switch.json"
    "$CONFIG_DIR/wake_on_lan.json"
    "$CONFIG_DIR/access_control_list.json"
    "$CONFIG_DIR/shortcuts.json"
)

log "启动 BliKVM 服务"
exec node src/index.js "${CONFIG_ARGS[@]}"
