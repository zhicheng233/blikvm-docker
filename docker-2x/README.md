# BliKVM 2.x 容器化（armhf / 通用 ARM）

把 BliKVM **2.x 开源版**（GPL-3.0）封装成特权容器，目标是让非官方 ARM 板
（本项目首个验证目标：Xunlei OneCloud / Amlogic S5 / meson8b / armv7l）也能跑
KVM-over-IP，用于**服务器运维**场景。

## 为什么是 2.x 而不是 3.x

| | 3.x | 2.x |
|---|---|---|
| 授权 | 无 LICENSE，全部 prerelease | **GPL-3.0**，源码完整 |
| 二进制 | Go，仅 aarch64 | JS 源码 + 少量 C 工具 |
| 视频编码 | **仅硬件编码**（v4l2m2m/cedar/rockit） | MJPEG 软件编码（CPU）可用 |
| 板型适配 | 硬编码进二进制，无法改 | `kvmd-video.sh` 几行 if，可改 |

3.x 对没有硬件 H.264 编码器的板子（如 OneCloud）是**物理上不可能**的；
2.x 可以靠 CPU 做 MJPEG 编码，代价是画质/帧率较低。

## 适用范围与已知限制

**适合**：服务器/工作站运维（BIOS/UEFI、文本控制台、安装界面），
实际分辨率通常 640x480 ~ 1280x1024。

**不适合**：需要 1080p 高帧率视频、需要 H.264 低带宽远传的场景。

**硬性前提**（缺一不可）：

- `armv7l` 或 `aarch64` Linux 主机
- 主机内核提供 USB Device/OTG 控制器（`/sys/class/udc` 非空）
- 主机内核 `configfs` + `libcomposite` + `usb_f_hid` / `usb_f_mass_storage`
- 一张 USB UVC 采集卡（本方案不做 CSI 桥 EDID 控制）

## 目录结构

```
docker-2x/
├── Dockerfile                      # arm32v7/debian + Node 20 + ustreamer，源码直跑
├── docker-compose.yml              # 特权模式 + 设备直通
├── entrypoint.sh                   # 容器启动：环境自检、目录准备、拉起服务
├── patches/
│   ├── apply-patches.sh            # 幂等打补丁脚本，构建期执行
│   └── kvmd-video.sh               # 替换上游：支持未知板型 + 源分辨率直出
├── tests/
│   └── patch-logic.test.mjs        # 板型判断与分辨率策略的纯逻辑测试
└── README.md
```

## 快速开始

```bash
git clone https://github.com/zhicheng233/blikvm-docker.git -b docker-2x
cd blikvm-docker/docker-2x
docker compose up -d --build
```

访问 `https://<host-ip>/`，默认账号见上游文档。

## 打了哪些补丁

上游代码把硬件型号写死了，非官方板直接失效。本方案改三处：

### 1. `lib/kvmd-video.sh` —— 整份替换

上游按 `/proc/device-tree/model` 判断板型，只认 Pi4 / CM4 / MangoPi Mcore，
其它板子 `exit 1`，视频服务起不来。

改为：

- 遍历 `/dev/video*`，选第一个支持 MJPEG 的节点
- **默认不传 `--resolution`**，按源分辨率直出
- 编码器默认 `CPU`（MJPEG 软编）

### 2. `src/common/tool.js` —— 板型兜底

`getHardwareType()` 对未知板返回 `UNKNOWN`，导致依赖它的 API（如分辨率切换）
直接拒绝服务。补充逻辑：

- 读 `/proc/device-tree/model` 失败时不再抛异常（容器环境常见）
- 未知型号但存在 `/dev/video*` 时返回新增的 `HardwareType.GENERIC`

### 3. `src/modules/update/app_default_config.js` —— 默认配置

- 未知板型返回 `'generic'` 而非 `'none'`（后者会让 `lib/none/ustreamer.bin` 路径不存在）
- 默认分辨率改为 `"native"`，配合视频脚本直出

补丁由 `patches/apply-patches.sh` 在构建期执行，具备幂等性：
重复执行会跳过已打的补丁；上游结构变化导致补丁打不上时会**立即报错退出**，
不会悄悄产出行为错误的镜像。

## 验证状态

| 项 | 状态 |
|---|---|
| 补丁逻辑（板型判断 / 分辨率策略） | ✅ 10/10 通过（`node --test tests/`） |
| 补丁脚本幂等性 | ✅ 重复执行正确跳过 |
| 打补丁后 JS 语法 | ✅ `node --check` 通过 |
| 镜像构建（OneCloud） | ⏳ 待验证 |
| 真机 MJPEG 帧率 / CPU 占用 | ⏳ 待验证 |

尚未在真机上验证的部分会明确标注，不提前声称可用。


## 设计要点

### 不打包 server_app

上游用 `pkg` 把 Node 源码和运行时打成单个 119 MB 的 `server_app`，
但 `.pkg.json` 的 target 写死为 `node18-linux-arm64`，原生模块
（`serialport`/`i2c-bus`/`bcrypt`）也只有 arm64 预编译产物。

本方案**直接跑 JS 源码**：镜像里装 Debian 的 armhf `nodejs` 20，
原生模块用 apt 包或现场编译。好处是：

- 不依赖 pkg 的交叉打包
- 换 Node 版本 / 打补丁都更直接
- 镜像更小（不用塞 119 MB 的 pkg 产物）

### 视频：MJPEG，源分辨率直出

上游 `kvmd-video.sh` 把板型写死（Pi4/CM4/MangoPi），未知板型直接 `exit 1`；
且强制 `--resolution=1920x1080` 缩放。

本方案改为：

1. 探测 `/dev/video*`，选第一个支持 MJPEG 的节点
2. **不传 `--resolution`**，按采集源原始分辨率输出

运维场景源分辨率普遍低于 720p，直出既省 CPU 又不糊字。

### 不启用 H.264

Debian armhf 的 `ustreamer` 不含 x264（编码器只有 CPU/HW/M2M-*/NOOP）。
上游 H616 版的 `ustreamer.bin` 虽然带 `libx264.so.163`，但是 arm64 二进制。

需要 H.264 时可自行编译带 x264 的 ustreamer（Dockerfile 预留 `WITH_X264` 参数），
但 Cortex-A5 @1.5GHz 做 1080p 实时编码不现实。

## 与上游的关系

- 本目录是**适配层**，不含上游源码；构建时从 GitHub 拉取并打补丁
- 补丁只改「板型判断」和「分辨率策略」，不改变业务逻辑
- 上游更新时，若 `kvmd-video.sh` 结构变化，补丁需要同步调整

## 许可证

上游 `blikvm-web-server` 为 GPL-3.0。本目录的补丁与脚本同样以 GPL-3.0 发布。
分发容器镜像时需同时提供对应源码（含补丁）。
