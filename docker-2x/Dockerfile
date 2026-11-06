# BliKVM 2.x 容器镜像（armhf / 通用 ARM）
#
# 基础镜像选 Debian trixie armhf：
#   - 与 OneCloud 上的 Armbian trixie 同代，glibc 兼容
#   - Debian 官方提供 armhf 的 nodejs 20 和 ustreamer，无需自编
#
# 不打包上游的 server_app（pkg 产物写死 node18-linux-arm64），
# 而是直接运行 JS 源码，原生模块用 apt 的 armhf 版本。
#
# 构建：
#   docker build -t blikvm:2.x-armhf .
#   docker build --build-arg BLIKVM_REF=<commit> -t blikvm:2.x-armhf .

# ---------------------------------------------------------------------------
# 构建阶段：拉源码 + 打补丁
# ---------------------------------------------------------------------------
FROM arm32v7/debian:trixie-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG BLIKVM_REPO=https://github.com/blikvm/blikvm-web-server.git
# 固定到具体 commit 以保证可复现；留空则用 master（不推荐用于发布）
ARG BLIKVM_REF=

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# 只取需要的源码，避免把 .git 历史带进镜像
# 注意：上游仓库含约 30MB 的预编译二进制（lib/ 下的 janus/ustreamer/ventoy），
# 必须完整克隆，不能稀疏检出，否则 lib/kvmd-video.sh 等脚本会缺失。
#
# BLIKVM_REF 可以是分支、tag 或完整 commit SHA；为空的默认与上游一致用 master。
# SHA 无法用 --branch 检出，所以统一走 fetch + checkout，并对浅取失败做回退。
RUN git init --quiet blikvm && cd blikvm \
    && git remote add origin "$BLIKVM_REPO" \
    && { git fetch --depth 1 origin "${BLIKVM_REF:-master}" \
         || git fetch origin "${BLIKVM_REF:-master}"; } \
    && git checkout --quiet --detach FETCH_HEAD \
    && cd /src && rm -rf blikvm/.git

# 补丁脚本与适配版视频脚本
COPY patches/ /opt/patches/
RUN chmod +x /opt/patches/apply-patches.sh /opt/patches/kvmd-video.sh

# 构建期需要 node 做语法检查，并需要编译原生模块
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        build-essential python3 pkg-config \
        libudev-dev libi2c-dev \
    && rm -rf /var/lib/apt/lists/*

RUN /opt/patches/apply-patches.sh /src/blikvm

# 安装 npm 依赖。
#
# 原生模块在 armhf 上没有预编译产物，必须现场编译：
#   serialport  - 串口功能（核心）
#   i2c-bus     - EEPROM 读板型（非官方板用不到，但 import 链会加载）
#   bcrypt      - 账号密码哈希（核心，缺失会导致无法登录）
#   evdev       - HID passthrough；src/index.js 无条件 import，缺失会导致启动崩溃
#
# ffi-napi / ref-napi 在本项目源码中未被 import，且在新版 Node 上
# 已知编译失败（它们最后维护于 Node 16 时代）。跳过它们以避免构建中断。
WORKDIR /src/blikvm
RUN npm install --omit=dev --no-audit --no-fund --ignore-scripts \
    && npm rebuild bcrypt serialport i2c-bus evdev --build-from-source \
    && npm cache clean --force 2>/dev/null || true

# ---------------------------------------------------------------------------
# 运行阶段
# ---------------------------------------------------------------------------
FROM arm32v7/debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# 运行时依赖说明：
#   nodejs           - 直接运行 JS 源码
#   ustreamer        - Debian 官方 armhf 构建（MJPEG 编码器齐全）
#   v4l-utils        - v4l2-ctl，用于选设备 / 设置 EDID / 排障
#   jq               - kvmd-msd.sh 依赖
#   libjpeg62-turbo  - ustreamer 运行时依赖
#   libudev1         - serialport 原生模块运行时依赖
#   udev             - 提供 udevadm；serialport 的 SerialPort.list() 在 Linux 上
#                      通过它枚举串口，缺失会导致串口设备列表为空（ENOENT）
#   ffmpeg           - 录制与格式转换（上游 fluent-ffmpeg 调用）
#   tesseract-ocr    - OCR 功能
#   bash iproute2 util-linux mount - 上游脚本依赖的常用工具
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs \
        ustreamer \
        v4l-utils \
        jq \
        libjpeg62-turbo \
        libevent-2.1-7t64 \
        libevent-pthreads-2.1-7t64 \
        libbsd0 \
        libudev1 \
        udev \
        ffmpeg \
        tesseract-ocr \
        bash \
        iproute2 \
        util-linux \
        mount \
        procps \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 原生 Node 模块由构建阶段编译完成，随源码一起复制
WORKDIR /opt/blikvm
COPY --from=builder /src/blikvm /opt/blikvm

# 容器内的运行目录布局（与上游 /mnt 结构对齐，减少脚本改动）
RUN mkdir -p \
        /mnt/tmp/logs \
        /mnt/tmp/record \
        /mnt/msd/user \
        /mnt/msd/config \
        /mnt/msd/ventoy \
        /media/blikvm/ventoy \
        /dev/shm/blikvm \
        /var/blikvm \
        /data/config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 上游默认端口：80/443 (Web) 10004 (ustreamer) 10002 (MSD tus)
EXPOSE 80 443 10004

# 健康检查：Web 服务起来即可访问
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -kfsS https://127.0.0.1/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
