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
│   ├── patch-logic.test.mjs        # 板型判断与分辨率策略的纯逻辑测试
│   └── verify-image.sh             # 镜像内冒烟测试（CI 里跑）
└── README.md
```

## 获取镜像

镜像由 GitHub Actions 构建（`.github/workflows/build-docker-2x.yml`），
不依赖任何一台本地机器：目标板只有 1 GB 内存，本地机器也没有 armhf 工具链。

两种获取方式：

```bash
# 1) 在线拉取（需要能访问 GHCR）
docker pull ghcr.io/zhicheng233/blikvm-2x-armhf:2.x-armhf

# 2) 离线导入（推荐：目标板跨境拉取实测只有 ~150 KB/s）
#    从 Actions 的 artifact "blikvm-2x-armhf-image" 下载后：
zstd -d blikvm-2x-armhf.tar.zst | docker load
```

CI 每次构建都会先跑冒烟测试再推送，验证内容包括：四个补丁确实落进镜像、
补丁后的 JS 仍能通过 `node --check`、六个原生模块是 armhf ELF 且能实际调用
（bcrypt 真算一次哈希、serialport 真枚举串口、koffi 真打开 `libxkbcommon` 并调用）、
ustreamer 可执行、入口脚本可执行。任一失败则不推送镜像。

自行构建（需要 armhf 环境或 QEMU binfmt）：

```bash
cd docker-2x
docker build --build-arg BLIKVM_REF=<commit> -t blikvm:2.x-armhf .
```

## 运行

```bash
cd docker-2x
docker compose up -d
```

访问 `https://<host-ip>/`，默认账号见上游文档。


## 打了哪些补丁

上游代码把硬件型号写死了，非官方板直接失效；另有一个 FFI 依赖在新版 Node 上根本编译不出来。本方案改四处：

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

### 4. `src/modules/hid/printer.js` —— FFI 后端换成 koffi

上游用 `ffi-napi` + `ref-napi` 在**模块加载期**绑定 `libxkbcommon`，用于把字符
转成 keysym（键盘「输入文本」功能）。这两个包最后维护于 Node 16 时代，
在 Node 20 上编译失败：

```
error: invalid conversion from 'napi_status (*)(node_api_basic_env, uv_loop_s**)'
       to 'get_uv_event_loop_fn' ...
```

（这是 CI 里实际跑出来的结论，不是推测：用一次性探针镜像逐个 `node-gyp rebuild`
验证过，`unix-dgram` / `ref-napi` 能编，`ffi-napi` / `cpu-features` 不能。）

又不能直接删掉 import —— 删了 `printer.js` 就少了 `textToWebKeys`，键盘输入文本
会失效。因此改用 [koffi](https://koffi.dev/)：维护活跃，自带 armhf 预编译产物
（`@koromix/koffi-linux-arm` 内的 `linux_armhf`），运行镜像不需要编译器。
调用语义等价，已在 armhf 容器里实测过返回值（`A`→0x41、`€`→0x20AC、
`中`→0x1004E2D）。

`cpu-features` 是 `ssh2` 的可选加速器，编译失败会被 `ssh2` 静默忽略，
因此不列入 `npm rebuild`（列入反而会让构建非零退出）。

## 验证状态

| 项 | 状态 |
|---|---|
| 补丁逻辑（板型判断 / 分辨率策略 / koffi 替换） | ✅ 27/27 通过（`node --test tests/`） |
| 补丁脚本幂等性 | ✅ 重复执行正确跳过 |
| 打补丁后 JS 语法 | ✅ `node --check` 通过 |
| 原生模块编译可行性（armhf + Node 20） | ✅ 探针实测：`unix-dgram`/`ref-napi` 可编，`ffi-napi`/`cpu-features` 不可编 |
| 镜像构建（GitHub Actions, linux/arm/v7） | ✅ 构建通过 |
| 镜像内冒烟测试 | ✅ 补丁 / ELF 架构 / 原生模块调用 / 视频后端 / 入口 |
| 容器启动（有硬件） | ⏳ 待验证 |
| 真机 MJPEG 帧率 / CPU 占用 | ⏳ 待验证 |
| HID 键鼠与 MSD 虚拟介质 | ⏳ 待验证 |

尚未在真机上验证的部分会明确标注，不提前声称可用。

构建期已经抓到并修掉的两个真实缺陷，都出在运行阶段而不是补丁逻辑：

- `evdev` 被 `src/index.js` 无条件间接 import，缺失会让服务直接崩溃
  （不是可选项，必须一起编译）
- 运行镜像缺 `udevadm`，`SerialPort.list()` 会失败，串口/ATX 功能不可用


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

需要 H.264 时可自行编译带 x264 的 ustreamer（Debian 有 `libx264-dev`），
但 Cortex-A5 @1.5GHz 做 1080p 实时编码不现实。

### 上游版本固定

`Dockerfile` 的 `BLIKVM_REF` 与 workflow 的 `UPSTREAM_REF`
都固定到 `blikvm-web-server` 的提交 `cecede74`（2025-12-18，最后一个非 alpha 的
master 快照）。上游若更新，需要同步改这两处并重新验证补丁是否仍能打上。


## 与上游的关系

- 本目录是**适配层**，不含上游源码；构建时从 GitHub 拉取并打补丁
- 补丁只改「板型判断」「分辨率策略」「FFI 后端」，不改变业务逻辑
- 上游更新时，若 `kvmd-video.sh` 或 `printer.js` 结构变化，补丁需要同步调整

## 许可证

上游 `blikvm-web-server` 为 GPL-3.0。本目录的补丁与脚本同样以 GPL-3.0 发布。
分发容器镜像时需同时提供对应源码（含补丁）。
