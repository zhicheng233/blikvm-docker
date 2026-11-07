# BliKVM 2.x 容器化（armhf / 通用 ARM）

把 BliKVM **2.x 开源版**（GPL-3.0）封装成特权容器，目标是让非官方 ARM 板
（本项目首个验证目标：Xunlei OneCloud / Amlogic S805 / meson8b / armv7l，
Armbian 26.11 trixie / 内核 6.12）也能跑 KVM-over-IP，用于**服务器运维**场景。

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

**armhf 通用板上不可用的功能**（上游只提供 aarch64 二进制，非本方案的疏漏）：

| 功能 | 依赖 | 通用板表现 |
|---|---|---|
| ATX 电源控制 / 风扇 / 外部切换器 | `kvmd-main`（aarch64 ELF） | 启动时跳过，界面相关按钮无效 |
| WebRTC 视频 | `janus`（aarch64 ELF） | 跳过；用 MJPEG 观看 |
| BliSwitch 串口切换器 | `/dev/ttyUSB*` 外接设备 | 默认关闭，接入后可手动启用 |

`lib/pi/` 与 `lib/h616/` 下所有预编译产物都是 **aarch64 ELF**（`e_machine=0xb7`），
armv7l 一个都跑不了，所以这些服务必须跳过而不是硬启。

另外前端 `index.html` 会从 `fonts.gstatic.com` 预加载字体，无外网时会退化到
系统字体 —— 不影响功能。

## 目录结构

```
docker-2x/
├── Dockerfile                      # 前端原生构建 + arm32v7 源码构建 + 运行镜像
├── docker-compose.yml              # 特权模式 + /dev、/sys、/lib/modules 直通
├── entrypoint.sh                   # 容器启动：环境自检、目录准备、拉起服务
├── patches/
│   ├── apply-patches.sh            # 幂等打服务端补丁，构建期执行
│   ├── apply-web-patches.sh        # 幂等打前端补丁，前端阶段构建前执行
│   └── kvmd-video.sh               # 替换上游：支持未知板型 + 源分辨率直出
├── tests/
│   ├── patch-logic.test.mjs        # 补丁逻辑纯函数测试（62 项）
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

CI 每次构建都会先跑冒烟测试再推送，验证内容包括：

- 8 个服务端补丁确实落进镜像；补丁后的 JS 仍能通过 `node --check`
- 六个原生模块是 armhf ELF 且能实际调用（bcrypt 真算一次哈希、
  serialport 真枚举串口、koffi 真打开 `libxkbcommon` 并调用）
- 前端产物 `src/server/dist/index.html` 存在（缺失会让整个 Web 界面 404）
- 前端补丁进了产物：`_disableGlobalStack` 存在、`中国人` 标签已消失
- `ustreamer` / `modprobe` / `v4l2-ctl` / `ffmpeg` 可用；入口脚本可执行

任一失败则不推送镜像。

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

访问 `https://<host-ip>/`。默认账号 `admin` / `admin`（首次登录后请立刻修改）。

外层 `docker-compose.yml` 已经处理了三件容易漏掉的事：

- `--privileged` + `/dev`：采集卡、UDC、loop 设备
- `/sys` 与 `/lib/modules:ro`：USB gadget 需要宿主的 configfs 与模块目录
- 容器镜像带 `kmod`，可在容器内 `modprobe libcomposite`

宿主侧建议先确认（否则 HID/MSD 建不出来）：

```bash
modprobe libcomposite
ls /sys/class/udc          # 必须非空
ls /dev/video*             # 插上采集卡之后才有
```

## 打了哪些补丁

上游代码把硬件型号写死了，非官方板直接失效；另有一个 FFI 依赖在新版 Node 上
根本编译不出来；还有几处只有在「直接跑源码而不是 pkg 二进制」时才会暴露。
本方案共 8 处服务端补丁，全部由 `patches/apply-patches.sh` 在构建期完成；
另有 2 处前端补丁，由 `patches/apply-web-patches.sh` 在前端阶段构建前完成
（见「[前端补丁](#前端补丁)」）。

### 1. `lib/kvmd-video.sh` —— 整份替换

上游按 `/proc/device-tree/model` 判断板型，只认 Pi4 / CM4 / MangoPi Mcore，
其它板子 `exit 1`，视频服务起不来。

改为：

- 遍历 `/dev/video*`，选第一个支持 MJPEG 的节点
- **默认不传 `--resolution`**，按源分辨率直出
- 编码器默认 `CPU`（MJPEG 软编）
- 传入的 `bin` 是命令名（`ustreamer`）时用 `command -v` 解析成绝对路径
- **没有采集设备时不退出**，每 10 秒重试；插入采集卡后自动出流
- 日志走 stderr（走 stdout 会被 `$(...)` 当成设备名捕获）

### 2. `src/common/tool.js` —— 板型兜底

`getHardwareType()` 对未知板返回 `UNKNOWN`，导致依赖它的 API（如分辨率切换）
直接拒绝服务。补充逻辑：

- 读 `/proc/device-tree/model` 失败时不再抛异常（容器环境常见）
- 未知型号但存在 `/dev/video*` 时返回新增的 `HardwareType.GENERIC`

### 3. `src/modules/update/app_default_config.js` —— 默认配置

- 未知板型返回 `'generic'` 而非 `'none'`（后者会让 `lib/none/ustreamer.bin` 路径不存在）
- 默认分辨率改为 `"native"`，配合视频脚本直出

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

### 5. `src/server/server.js` —— 补回 ESM 下缺失的 `__dirname`

上游用 `pkg` 把源码打包成 CommonJS，所以这里直接用了 CJS 的 `__dirname`
定位前端静态目录。本方案以 ESM 跑源码，该全局不存在 —— 第一次 HTTP 请求
（`getRootPath()`）就会 `ReferenceError` 并终止进程。

补丁从 `import.meta.url` 还原：

```js
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
```

### 6. `config/app.json` —— 初始配置里的二进制路径

这是最容易漏的一处：`entrypoint` 首次启动就把 `config/*.json` 复制到
`/data/config`，而 `app_default_config.js` 只在版本升级时补缺失字段。
所以**真正生效的初始值来自这个文件**，它把 ustreamer/janus/kvmd-main
全指向 `./lib/pi/...`（aarch64）。

改为：`video.bin=ustreamer`、`recordBin=''`、`resolution=native`、
`janus.bin=''`、`kvmd.bin=''`、`atx.isActive=false`。

### 7. `config/switch.json` —— 默认不启用 BliSwitch

默认配置 `kvmSwitch.isActive=true` 且指向 `/dev/ttyUSB0`。通用板没有这个串口，
`startSwitch()` 会先初始化失败报一条 `Switch path ... doesn't exist` 再自己
关掉。初始值直接置 `false`，需要外接切换器时在界面上重新启用。

### 8. `src/index.js` —— 可选子服务的失败不能拖垮主进程

上游把 video / kvmd-main / janus / ATX 都当必选服务：

- `startService()` 多数调用点没有 `.catch()`，任一子进程以 code 1 退出就会
  产生未处理的 Promise rejection，Node 20 直接终止进程
- `janus` / `kvmd-main` 在通用板上没有可执行文件，`spawn('')` 会**同步**抛
  `ERR_INVALID_ARG_VALUE`
- ATX 无条件 `fs.watch('/dev/shm/blikvm/atx')`，该文件由 kvmd-main 创建，
  不存在时抛 `ENOENT` 同样终止进程

补丁只做两件事：给异步启动补 `.catch()`；在 `bin` 为空时**跳过**该服务而非
调用它。不改变任何业务逻辑。

### 幂等与失败策略

补丁脚本具备幂等性：重复执行会跳过已打的补丁；上游结构变化导致补丁打不上时
会**立即报错退出**，不会悄悄产出行为错误的镜像。每个补丁块都配有对应的
`grep`/`node --check` 校验。

## 前端产物

`src/server/dist` 不是上游仓库自带的（上游是 pkg 打进去的），必须自己构建。
`Dockerfile` 里单独设了一个前端阶段：

- 仓库：`blikvm/blikvm-web-client`
- 固定 commit：`7062dc33`（2025-12-16）—— 这是**最后一个 Vue 版**；
  之后该仓库被改成了面向 RV1126B 3.0.3 的 WebRTC demo，与本后端不匹配
- `FROM --platform=$BUILDPLATFORM`：前端是纯 JS 产物，与目标架构无关。
  在 armhf QEMU 里装几百 MB 依赖会慢到不可用，甚至把 1GB 的构建机拖死
- 构建完断言 `dist/index.html` 存在，然后 `COPY` 到 `/opt/blikvm/src/server/dist`

### 前端补丁

`patches/apply-web-patches.sh` 在前端阶段 `npm run build` **之前**执行，
同样是幂等 + fail closed（锚点找不到就退出，不让构建「成功」出一个坏前端）。

**1. 设置面板里的下拉框点了没反应**（`src/components/AppDiagnosticsSignal.vue`）

真机复现出来的现象：进入「设置 → 图形用户界面 → 语言」，点下拉框没有任何选项
弹出。用浏览器调试后确认菜单**是被画出来了的**，只是整块压在左侧抽屉底下。

成因是两套 z-index 撞车：

| 来源 | 值 |
|---|---|
| 「未检测到信号」诊断浮层，取自 `src/styles/zIndex.js` 的 `diagnostics` | 700 |
| Vuetify `useStack` 给之后打开的菜单取「栈顶 + 10」 | 710 |
| 嵌套 `v-layout` 的抽屉（`rootZIndex - 100 = 900`，再加图层偏移） | 904 |

710 < 904，菜单完全被抽屉遮住，`document.elementFromPoint()` 命中的是面板卡片
而不是菜单项。**只要没插采集卡**（诊断浮层一直显示）就会触发，插着卡的机器上
浮层消失、菜单正常 —— 这也是上游一直没发现它的原因。

修法：给这个纯展示用的浮层加 `:_disable-global-stack="true"`，让它不参与
Vuetify 全局 overlay 栈，后续菜单回落到自己的默认 z-index。

**2. 语言下拉里的标签写错了**（`src/composables/useLanguage.js`）

上游把 `zh` 的 label 写成 `'中国人'`。下拉里显示的是「中国人」而不是「中文」，
很容易让人以为这里没有中文选项。改为 `'中文'`。

两项都在 CI 里对**最终产物**（压缩后的 `dist/assets`）做 grep 断言，
而不是只检查源码 —— 保证补丁真的进了用户拿到的镜像。

## 验证状态

| 项 | 状态 |
|---|---|
| 补丁逻辑（板型 / 分辨率 / 二进制路径 / koffi / ESM / 配置 / 子服务 / 前端） | ✅ 62/62 通过（`node --test tests/`） |
| 补丁脚本幂等性 | ✅ 真机对镜像源码重复执行两遍，第二遍全部跳过 |
| 打补丁后 JS 语法 | ✅ `node --check` 通过 |
| 原生模块编译可行性（armhf + Node 20） | ✅ 探针实测：`unix-dgram`/`ref-napi` 可编，`ffi-napi`/`cpu-features` 不可编 |
| 镜像构建（GitHub Actions, linux/arm/v7） | ✅ 构建通过 |
| 镜像内冒烟测试 | ✅ 补丁 / ELF 架构 / 原生模块调用 / 前端 dist / 前端补丁 / 视频后端 / 入口 |
| 容器启动（OneCloud 真机） | ✅ `Up (healthy)`，日志无 ERROR |
| Web 界面 | ✅ `https://<ip>/` 200，静态资源 200，80 自动跳 443 |
| 登录 | ✅ `POST /api/login` 200，JWT 签发、bcrypt 校验、`/api/auth/state` 200 |
| HID gadget | ✅ `/dev/hidg0/1/2` 全部打开，`HID already running` |
| 无采集卡时的行为 | ✅ 视频服务等待不退出，其余功能正常 |
| 设置面板下拉（无采集卡） | ✅ 修复后语言菜单可见，点击可真实切换语言 |
| MJPEG 实际出流 / 帧率 / CPU | ⏳ 待插采集卡验证 |
| HID 键盘鼠标向目标机实际输入 | ⏳ 待验证 |
| MSD 虚拟介质挂载 | ⏳ 待验证 |
| ATX / 风扇 / BliSwitch | ❌ armhf 不可用（kvmd-main 为 aarch64） |

尚未在真机上验证的部分会明确标注，不提前声称可用。

真机迭代中抓到并修掉的运行时缺陷（都只在「直接跑源码」时才暴露）：

- `server.js` 的 `__dirname` 在 ESM 下不存在 → 首个请求即崩
- `config/app.json` 的默认二进制路径指向 aarch64 产物 → 视频永远起不来
- `index.js` 没有隔离子服务失败 → 缺 janus/kvmd-main 时整体退出
- ATX 无条件监视 kvmd-main 的状态文件 → 文件不存在时 `ENOENT` 杀进程
- `kvmd-video.sh` 用 `[ -x ]` 检查命令名 → 误报「ustreamer 不可执行」；
  日志写 stdout → 被 `$(pick_capture_device)` 当成设备名
- 运行镜像缺 `udevadm` → `SerialPort.list()` 失败
- `evdev` 被无条件 import → 缺失直接崩溃
- 前端诊断浮层占用 Vuetify 全局 z-index 栈 → 没插采集卡时设置面板里所有
  下拉框都被抽屉盖住（点了没反应，菜单其实在，只是看不见）

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
master 快照）。前端固定到 `blikvm-web-client` 的 `7062dc33`（2025-12-16）。
上游若更新，需要同步改这几处并重新验证补丁是否仍能打上。

## 与上游的关系

- 本目录是**适配层**，不含上游源码；构建时从 GitHub 拉取并打补丁
- 补丁只改「板型判断」「分辨率策略」「二进制路径」「FFI 后端」「可选服务的
  失败隔离」，不改变业务逻辑
- 上游更新时，若相关文件结构变化，补丁会 fail closed，需要同步调整

## 许可证

上游 `blikvm-web-server` 为 GPL-3.0。本目录的补丁与脚本同样以 GPL-3.0 发布。
分发容器镜像时需同时提供对应源码（含补丁）。