#!/bin/bash
#
# 镜像内容冒烟测试：在目标镜像内部运行。
#
# 目的不是测功能（那需要真实硬件），而是确认镜像本身没被构建过程毁掉：
#   - 补丁确实落进镜像，不是只在构建上下文里
#   - 补丁后的 JS 仍然能被 Node 解析
#   - 原生模块真的编译成了 armhf 机器码，并且能加载、能运行
#   - 视频后端与入口脚本存在且可执行
#
# 用法（在 CI 里）：
#   docker run --rm --platform linux/arm/v7 \
#     -v "$PWD/docker-2x/tests:/verify:ro" \
#     --entrypoint bash blikvm-2x:ci /verify/verify-image.sh
#
# 本文件以 GPL-3.0 发布（与上游 blikvm-web-server 一致）。

set -u

APP_DIR="${APP_DIR:-/opt/blikvm}"
rc=0

report() { echo "FAIL: $*"; rc=1; }
ok()     { echo "ok:   $*"; }

# ---------------------------------------------------------------------------
# 1. 补丁是否落进镜像
# ---------------------------------------------------------------------------
echo "--- 补丁 ---"

grep -q "GENERIC" "$APP_DIR/src/common/enums.js" \
    && ok "enums.js 有 GENERIC" || report "enums.js 缺少 GENERIC"
grep -q "hasV4L2Capture" "$APP_DIR/src/common/tool.js" \
    && ok "tool.js 已补丁" || report "tool.js 未打补丁"
grep -q "generic" "$APP_DIR/src/modules/update/app_default_config.js" \
    && ok "app_default_config 已补丁" || report "app_default_config.js 未打补丁"
grep -q "pick_capture_device" "$APP_DIR/lib/kvmd-video.sh" \
    && ok "kvmd-video.sh 已替换" || report "kvmd-video.sh 未替换"
grep -q '"native"' "$APP_DIR/src/modules/update/app_default_config.js" \
    && ok "默认分辨率为 native" || report "默认分辨率未改为 native"

# device-tree 容错：这一行在模块加载期执行，缺容错会让容器直接崩溃
grep -q "modelOutput = ''" "$APP_DIR/src/modules/update/app_default_config.js" \
    && ok "app_default_config device-tree 容错" || report "app_default_config 缺 device-tree 容错"

# 通用板不能指向 lib/generic 下不存在的二进制
if grep -q 'isGeneric' "$APP_DIR/src/modules/update/app_default_config.js"; then
    ok "通用板二进制路径已改写"
else
    report "通用板仍会指向 lib/generic/ustreamer.bin"
fi

# printer.js 必须已脱离 ffi-napi：它在 Node 20 上编译不出来，
# 残留任何 import 都会让进程在加载期崩溃
grep -q "koffi.load('libxkbcommon" "$APP_DIR/src/modules/hid/printer.js" \
    && ok "printer.js 使用 koffi" || report "printer.js 未改用 koffi"
if grep -q "ffi-napi" "$APP_DIR/src/modules/hid/printer.js"; then
    report "printer.js 仍引用 ffi-napi"
else
    ok "printer.js 无 ffi-napi 残留"
fi

# ---------------------------------------------------------------------------
# 2. 补丁后的 JS 必须仍然可解析
# ---------------------------------------------------------------------------
echo "--- 语法 ---"

for f in src/common/enums.js src/common/tool.js src/modules/update/app_default_config.js src/modules/hid/printer.js; do
    if node --check "$APP_DIR/$f" 2>/dev/null; then
        ok "$f"
    else
        report "$f 语法错误"
    fi
done
bash -n "$APP_DIR/lib/kvmd-video.sh" \
    && ok "kvmd-video.sh" || report "kvmd-video.sh 语法错误"

# ---------------------------------------------------------------------------
# 3. 原生模块必须是 armhf 机器码
# ---------------------------------------------------------------------------
# 读 ELF 头而不是调 readelf，避免为了一个检查往 slim 镜像里塞 binutils。
# e_machine = 40 (EM_ARM) 才是 armhf；183 是 AArch64，62 是 x86_64。
#
# 辅助脚本必须写在 $APP_DIR 里，不能放 /tmp：
# Node 按「脚本所在目录」向上查找 node_modules，放到 /tmp 会找不到
# 依赖，表现为 Cannot find module，与架构无关却会误报。
echo "--- 原生模块架构 ---"

cat > "$APP_DIR/.verify-check-elf.cjs" <<'EOF'
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const label = process.argv[3];

if (!fs.existsSync(root)) {
  console.error(`${label}: 目录不存在 ${root}`);
  process.exit(1);
}

const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const p = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(p) : [p];
  });

const nodes = walk(root).filter((f) => f.endsWith('.node'));
if (!nodes.length) {
  console.error(`${label}: 没有 .node 产物`);
  process.exit(1);
}

// 该包可能同时带多个平台的预编译文件，只要有一个是 ARM 即算通过
const arms = nodes.filter((f) => {
  const b = fs.readFileSync(f);
  return b.length > 20 && b[0] === 0x7f && b[1] === 0x45 && b.readUInt16LE(18) === 40;
});

if (!arms.length) {
  const found = nodes.map((f) => path.basename(f)).join(', ');
  console.error(`${label}: 无 ARM ELF，候选 ${found}`);
  process.exit(1);
}

console.log(arms.map((f) => path.basename(f)).join(', '));
EOF

check_elf() {  # $1=对外显示名  $2=实际含绑定的包目录
    if out=$(node "$APP_DIR/.verify-check-elf.cjs" "$APP_DIR/node_modules/$2" "$1" 2>&1); then
        ok "$1 ($out)"
    else
        report "$1 不是 armhf 二进制: $out"
    fi
}

check_elf bcrypt     bcrypt
# serialport v12 是纯 JS 包装，真正的绑定在 @serialport/bindings-cpp
check_elf serialport "@serialport/bindings-cpp"
check_elf i2c-bus    i2c-bus
check_elf evdev      evdev
# atx.route.js 在加载期 import unix-dgram，缺绑定会让启动崩溃
check_elf unix-dgram unix-dgram
# koffi 自带 armhf 预编译产物，不需要编译，但必须是 ARM 机器码。
# 注意：主包 koffi/ 里只有一个平台选择器，真正的二进制在平台子包
# @koromix/koffi-linux-arm/linux_armhf/ 下，所以要指到子包目录。
if [ -d "$APP_DIR/node_modules/@koromix/koffi-linux-arm" ]; then
    check_elf koffi "@koromix/koffi-linux-arm"
else
    check_elf koffi koffi
fi

# ---------------------------------------------------------------------------
# 4. 原生模块必须能实际运行，不只是 require 成功
# ---------------------------------------------------------------------------
echo "--- 原生模块运行时 ---"

cat > "$APP_DIR/.verify-run-native.cjs" <<'EOF'
const checks = [];

// bcrypt：真正算一次哈希，静态链接问题只在调用时暴露
try {
  const bcrypt = require('bcrypt');
  const hash = bcrypt.hashSync('blikvm-smoke-test', 4);
  if (!bcrypt.compareSync('blikvm-smoke-test', hash)) throw new Error('哈希校验不一致');
  checks.push('bcrypt 哈希正常');
} catch (e) {
  checks.push(`bcrypt 失败: ${e.message}`);
  process.exitCode = 1;
}

// serialport：加载本身会进入绑定层
try {
  require('serialport');
  checks.push('serialport 已加载');
} catch (e) {
  checks.push(`serialport 失败: ${e.message}`);
  process.exitCode = 1;
}

// i2c-bus：容器内通常没有 /dev/i2c-*，只验证模块可加载
try {
  require('i2c-bus');
  checks.push('i2c-bus 已加载');
} catch (e) {
  checks.push(`i2c-bus 失败: ${e.message}`);
  process.exitCode = 1;
}

// evdev 由 src/index.js 无条件 import，缺失会直接导致启动崩溃
try {
  require('evdev');
  checks.push('evdev 已加载');
} catch (e) {
  checks.push(`evdev 失败: ${e.message}`);
  process.exitCode = 1;
}

// unix-dgram 由 src/server/api/atx.route.js import，用于 ATX 电源控制
try {
  require('unix-dgram');
  checks.push('unix-dgram 已加载');
} catch (e) {
  checks.push(`unix-dgram 失败: ${e.message}`);
  process.exitCode = 1;
}

// koffi 是 printer.js 的 FFI 后端：必须能真的打开 libxkbcommon 并调用函数。
// 只 require 成功不够 —— dlopen 是在 load() 时才发生的。
try {
  const koffi = require('koffi');
  const lib = koffi.load('libxkbcommon.so.0');
  const toKeysym = lib.func('uint32 xkb_utf32_to_keysym(uint32)');
  const a = toKeysym(0x41);
  const cjk = toKeysym(0x4e2d);
  if (a !== 0x41) throw new Error(`A 的 keysym 期望 0x41，实际 0x${a.toString(16)}`);
  if (cjk !== 0x1004e2d) throw new Error(`U+4E2D 的 keysym 期望 0x1004E2D，实际 0x${cjk.toString(16)}`);
  checks.push(`koffi + libxkbcommon 正常 (koffi ${koffi.version})`);
} catch (e) {
  checks.push(`koffi/libxkbcommon 失败: ${e.message}`);
  process.exitCode = 1;
}

for (const c of checks) console.log(`  ${c}`);
EOF

if out=$(node "$APP_DIR/.verify-run-native.cjs" 2>&1); then
    echo "$out"
    ok "原生模块运行时检查通过"
else
    echo "$out"
    report "原生模块运行时检查失败"
fi

# 串口枚举是异步的，单独跑一次以捕获绑定层的运行期错误
cat > "$APP_DIR/.verify-list-serial.cjs" <<'EOF'
const { SerialPort } = require('serialport');
SerialPort.list()
  .then((ports) => {
    console.log(`  枚举到 ${ports.length} 个串口`);
    process.exit(0);
  })
  .catch((e) => {
    console.error(`  ${e.message}`);
    process.exit(1);
  });
EOF

if out=$(node "$APP_DIR/.verify-list-serial.cjs" 2>&1); then
    echo "$out"
    ok "串口枚举可用"
else
    echo "$out"
    report "串口枚举失败"
fi

rm -f "$APP_DIR"/.verify-*.cjs

# ---------------------------------------------------------------------------
# 5. 视频后端与运行期依赖
# ---------------------------------------------------------------------------
echo "--- 视频后端 ---"

command -v ustreamer >/dev/null && ok "ustreamer 存在" || report "缺少 ustreamer"
ustreamer --help >/dev/null 2>&1 && ok "ustreamer 可执行" || report "ustreamer 无法运行"

# Debian armhf 的 ustreamer 不带 x264，这一点要在构建期就明确，
# 避免运行时才发现只能软编
if ustreamer --help 2>&1 | grep -qi "LIBX264"; then
    ok "ustreamer 含 x264 编码器"
else
    echo "info: ustreamer 不含 x264（armhf 官方包只有 MJPEG，符合预期）"
fi

command -v v4l2-ctl >/dev/null && ok "v4l2-ctl 存在" || report "缺少 v4l2-ctl"
command -v jq >/dev/null && ok "jq 存在" || report "缺少 jq"
command -v ffmpeg >/dev/null && ok "ffmpeg 存在" || report "缺少 ffmpeg"

# ---------------------------------------------------------------------------
# 6. 入口与配置
# ---------------------------------------------------------------------------
echo "--- 入口 ---"

[ -x /usr/local/bin/entrypoint.sh ] \
    && ok "entrypoint.sh 可执行" || report "entrypoint.sh 不可执行"
bash -n /usr/local/bin/entrypoint.sh \
    && ok "entrypoint.sh 语法正常" || report "entrypoint.sh 语法错误"

# 上游入口按位置参数接收 5 个配置文件，缺一个都会启动失败
cnt=$(ls "$APP_DIR"/config/*.json 2>/dev/null | wc -l)
if [ "$cnt" -ge 5 ]; then
    ok "默认配置文件 $cnt 个"
else
    report "默认配置文件只有 $cnt 个，少于 5 个"
fi

[ -f "$APP_DIR/src/index.js" ] && ok "src/index.js 存在" || report "缺少 src/index.js"

echo
if [ "$rc" -eq 0 ]; then
    echo "全部检查通过"
else
    echo "存在失败项"
fi
exit "$rc"
