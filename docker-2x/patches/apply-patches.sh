#!/bin/bash
#
# 在构建期对上游 blikvm-web-server 源码打补丁。
#
# 设计原则：
#   - 幂等：重复执行不会重复打补丁
#   - 可失败：如果上游结构变化导致补丁打不上，立即报错退出（fail closed），
#     避免悄悄产出行为错误的镜像
#
# 用法：apply-patches.sh <源码根目录>
#
# 本文件以 GPL-3.0 发布（与上游 blikvm-web-server 一致）。

set -euo pipefail

SRC="${1:-/opt/blikvm}"
# 补丁资源目录，镜像内固定为 /opt/patches，本地测试可覆盖
PATCH_DIR="${PATCH_DIR:-/opt/patches}"
cd "$SRC"

log() { echo "[patch] $*"; }
die() { echo "[patch] ERROR: $*" >&2; exit 1; }

[ -f src/common/tool.js ] || die "找不到 src/common/tool.js，源码目录不对: $SRC"
[ -f src/common/enums.js ] || die "找不到 src/common/enums.js"
[ -f src/modules/update/app_default_config.js ] || die "找不到 app_default_config.js"
[ -f src/modules/hid/printer.js ] || die "找不到 src/modules/hid/printer.js"

# ---------------------------------------------------------------------------
# 1) enums.js：新增 HardwareType.GENERIC
# ---------------------------------------------------------------------------
if grep -q "GENERIC" src/common/enums.js; then
    log "enums.js 已打过补丁，跳过"
else
    log "打补丁: enums.js 新增 GENERIC"
    python3 - <<'PY'
import re, sys
p = 'src/common/enums.js'
s = open(p, encoding='utf-8').read()
# 在 HardwareType 对象内部、BliKVMV5CM4 之后追加 GENERIC
m = re.search(r'(BliKVMV5CM4:\s*4)\s*\n(\s*\};)', s)
if not m:
    sys.exit('enums.js: 找不到 HardwareType 对象结尾，上游结构可能已变化')
addition = (
    ",\n"
    "  /**\n"
    "   * 通用 ARM 板：非官方硬件，但有标准 V4L2 采集设备 + USB gadget。\n"
    "   * 用于容器化 / 第三方板卡适配。\n"
    "   */\n"
    "  GENERIC: 5,"
)
s = s[:m.end(1)] + addition + s[m.start(2):]
open(p, 'w', encoding='utf-8').write(s)
print('enums.js patched')
PY
fi

# ---------------------------------------------------------------------------
# 2) tool.js：device-tree 读取容错 + 未知板型兜底为 GENERIC
# ---------------------------------------------------------------------------
if grep -q "hasV4L2Capture" src/common/tool.js; then
    log "tool.js 已打过补丁，跳过"
else
    log "打补丁: tool.js 未知板型兜底"
    python3 - <<'PY'
import sys
p = 'src/common/tool.js'
s = open(p, encoding='utf-8').read()

# 2a) execSync('cat /proc/device-tree/model') 加容错
old_read = "    const modelOutput = execSync('cat /proc/device-tree/model').toString();"
new_read = (
    "    let modelOutput = '';\n"
    "    try {\n"
    "      modelOutput = execSync('cat /proc/device-tree/model').toString();\n"
    "    } catch (e) {\n"
    "      // 容器/虚拟环境可能没有 device-tree，不能因此崩溃\n"
    "      modelOutput = '';\n"
    "    }"
)
if old_read in s:
    s = s.replace(old_read, new_read, 1)
elif "let modelOutput = '';" not in s:
    sys.exit('tool.js: 找不到 model 读取语句，上游结构可能已变化')

# 2b) 在 getHardwareType 的最后一个 else 前插入 GENERIC 兜底
#     定位 CM4 分支结束后的闭合大括号
marker = "    }\n  }\n  return hardwareSysType;\n}"
if marker not in s:
    sys.exit('tool.js: 找不到 getHardwareType 结尾，上游结构可能已变化')
inject = (
    "    } else if (hasV4L2Capture()) {\n"
    "      // 非官方板，但存在标准 V4L2 采集设备：按通用板处理\n"
    "      hardwareSysType = HardwareType.GENERIC;\n"
    "    }\n"
    "  }\n"
    "  return hardwareSysType;\n"
    "}\n"
    "\n"
    "/**\n"
    " * 检测是否存在 V4L2 采集节点。\n"
    " * 用于把「非官方板 + USB 采集卡」识别为可用的通用平台。\n"
    " * @returns {boolean}\n"
    " */\n"
    "function hasV4L2Capture() {\n"
    "  try {\n"
    "    const nodes = fs.readdirSync('/dev').filter((n) => /^video\\d+$/.test(n));\n"
    "    return nodes.length > 0;\n"
    "  } catch (e) {\n"
    "    return false;\n"
    "  }\n"
    "}"
)
s = s.replace(marker, inject, 1)
open(p, 'w', encoding='utf-8').write(s)
print('tool.js patched')
PY
fi

# ---------------------------------------------------------------------------
# 3) app_default_config.js：未知板型的默认配置指向可用的通用路径
# ---------------------------------------------------------------------------
if grep -q "'generic'" src/modules/update/app_default_config.js; then
    log "app_default_config.js 已打过补丁，跳过"
else
    log "打补丁: app_default_config.js 通用板默认配置"
    python3 - <<'PY'
import sys
p = 'src/modules/update/app_default_config.js'
s = open(p, encoding='utf-8').read()

old = """    } else {
      return 'none';
    }"""
new = """    } else {
      // 非官方板：使用通用路径，视频脚本会自行探测采集设备
      return 'generic';
    }"""
if old not in s:
    sys.exit('app_default_config.js: 找不到硬件类型兜底分支，上游结构可能已变化')
s = s.replace(old, new, 1)

# 默认分辨率改为「直出」，避免强制缩放导致文字模糊
s = s.replace('"resolution": "1920x1080"', '"resolution": "native"', 1)

open(p, 'w', encoding='utf-8').write(s)
print('app_default_config.js patched')
PY
fi

# ---------------------------------------------------------------------------
# 3a) app_default_config.js：device-tree 读取容错
# ---------------------------------------------------------------------------
# 必须单独成一个幂等块。这一行在模块加载期就执行，没有 /proc/device-tree
# （容器、虚拟机）会直接让进程崩溃；而崩溃发生在 import 阶段，
# 连日志和兜底逻辑都来不及跑。之前把它塞进上一块里，导致已经打过
# 'generic' 补丁的源码树会跳过这项修复 —— 校验步骤抓到了这个漏洞。
if grep -q "modelOutput = ''" src/modules/update/app_default_config.js; then
    log "app_default_config.js device-tree 容错已打过补丁，跳过"
else
    log "打补丁: app_default_config.js device-tree 容错"
    python3 - <<'PY'
import sys
p = 'src/modules/update/app_default_config.js'
s = open(p, encoding='utf-8').read()

old_read = "    const modelOutput = execSync('cat /proc/device-tree/model').toString();"
new_read = """    let modelOutput = '';
    try {
      modelOutput = execSync('cat /proc/device-tree/model').toString();
    } catch (e) {
      // 容器/虚拟环境通常没有 device-tree，按通用板处理
      modelOutput = '';
    }"""
if old_read not in s:
    sys.exit('app_default_config.js: 找不到 model 读取语句，上游结构可能已变化')
s = s.replace(old_read, new_read, 1)

open(p, 'w', encoding='utf-8').write(s)
print('app_default_config.js device-tree tolerance patched')
PY
fi

# ---------------------------------------------------------------------------
# 3d) 二进制路径：lib/<board>/ 下没有 generic 目录
# ---------------------------------------------------------------------------
# 上游把 ustreamer/janus/kvmd-main 的路径写成 `./lib/${hardware}/...`，
# 只有 pi / h616 两套预编译产物。通用板用的是系统 ustreamer，
# 必须把这些路径改成宿主 PATH 里的命令名，否则视频脚本拿到的是
# 一个不存在的 ./lib/generic/ustreamer.bin。
if grep -q 'genericBin' src/modules/update/app_default_config.js; then
    log "app_default_config.js 二进制路径已打过补丁，跳过"
else
    log "打补丁: app_default_config.js 通用板二进制路径"
    python3 - <<'PY'
import re, sys
p = 'src/modules/update/app_default_config.js'
s = open(p, encoding='utf-8').read()

# 在 hardware 常量之后声明通用板要用的命令名
anchor = "const hardware = getHardwareTypeForConfig();"
if anchor not in s:
    sys.exit('app_default_config.js: 找不到 hardware 常量，上游结构可能已变化')
inject = anchor + """

// 通用板（容器/非官方硬件）没有 lib/<board>/ 预编译产物，
// 直接用系统 PATH 里的同名命令。ustreamer 来自 Debian 的 armhf 包，
// janus / kvmd-main 在本方案中不启用（见 README 的视频与 USB 章节）。
const isGeneric = hardware === 'generic';
const genericBin = { ustreamer: 'ustreamer', janus: '', kvmd: '' };
"""
s = s.replace(anchor, inject, 1)

# 把 `${hardware}` 形式的路径换成对通用板安全的形式
repls = [
    ("\"bin\": `./lib/${hardware}/ustreamer.bin`",
     "\"bin\": isGeneric ? genericBin.ustreamer : `./lib/${hardware}/ustreamer.bin`"),
    ("\"recordBin\": `./lib/${hardware}/ustreamer-dump`",
     "\"recordBin\": isGeneric ? '' : `./lib/${hardware}/ustreamer-dump`"),
    ("\"bin\": `./lib/${hardware}/janus`",
     "\"bin\": isGeneric ? genericBin.janus : `./lib/${hardware}/janus`"),
    ("\"configsFolder\": `./lib/${hardware}/janus_configs`",
     "\"configsFolder\": isGeneric ? '' : `./lib/${hardware}/janus_configs`"),
    ("\"pluginsFolder\": `./lib/${hardware}/janus_plugins`",
     "\"pluginsFolder\": isGeneric ? '' : `./lib/${hardware}/janus_plugins`"),
    ("\"bin\": `./lib/${hardware}/kvmd-main`",
     "\"bin\": isGeneric ? genericBin.kvmd : `./lib/${hardware}/kvmd-main`"),
]
for old, new in repls:
    if old not in s:
        sys.exit(f'app_default_config.js: 找不到路径 {old}，上游结构可能已变化')
    s = s.replace(old, new, 1)

open(p, 'w', encoding='utf-8').write(s)
print('app_default_config.js binary paths patched')
PY
fi

# ---------------------------------------------------------------------------
# 3e) printer.js：用 koffi 取代 ffi-napi / ref-napi
# ---------------------------------------------------------------------------
# printer.js 在「模块加载期」就通过 FFI 绑定 libxkbcommon：
#   import ffi from 'ffi-napi';
#   const libxkbcommon = ffi.Library('libxkbcommon', { xkb_utf32_to_keysym: ... });
# 而 ffi-napi 在 Node 20 上无法编译：它的 node-addon-api 版本早于 NAPI 的
# node_api_basic_env / const napi_env 变更（CI 探测已确认编译报错）。
# 上游也已停止维护，没有可用的新版本。
#
# 不能简单删掉 import：键盘的「输入文本」功能依赖 xkb_utf32_to_keysym。
# 改用 koffi：维护活跃、自带 armhf 预编译产物（@koromix/koffi-linux-arm，
# 内含 linux_armhf 二进制），调用语义等价，已在 armhf 容器内实测过返回值。
if grep -q "koffi.load('libxkbcommon" src/modules/hid/printer.js; then
    log "printer.js 已打过补丁，跳过"
else
    log "打补丁: printer.js 改用 koffi 绑定 libxkbcommon"
    python3 - <<'PY'
import sys
p = 'src/modules/hid/printer.js'
s = open(p, encoding='utf-8').read()

# 3e-1) 替换 import
old_imports = "import ffi from 'ffi-napi';\nimport ref from 'ref-napi';\n"
new_imports = "import koffi from 'koffi';\n"
if old_imports in s:
    s = s.replace(old_imports, new_imports, 1)
elif new_imports not in s:
    sys.exit('printer.js: 找不到 ffi-napi / ref-napi 的 import，上游结构可能已变化')

# 3e-2) 替换 ffi.Library 绑定块（含 ref.types.uint32 声明）
old_lib = """// 定义 XKB 字符串类型
const uint32 = ref.types.uint32;

// 加载 xkbcommon 库
const libxkbcommon = ffi.Library('libxkbcommon', {
    'xkb_utf32_to_keysym': ['uint32', ['uint32']], // xkb_utf32_to_keysym 函数
});
"""
new_lib = """// libxkbcommon 通过 koffi 绑定。
// 不用 ffi-napi：它在 Node 20 上编译失败（NAPI 签名变更），且已停止维护。
// koffi 自带 armhf 预编译产物，运行镜像不需要编译器。
const libxkbcommon = koffi.load('libxkbcommon.so.0');
const xkb_utf32_to_keysym = libxkbcommon.func('uint32 xkb_utf32_to_keysym(uint32)');
"""
if old_lib in s:
    s = s.replace(old_lib, new_lib, 1)
elif "koffi.load('libxkbcommon" not in s:
    sys.exit('printer.js: 找不到 ffi.Library 绑定块，上游结构可能已变化')

# 3e-3) 调用点
old_call = 'libxkbcommon.xkb_utf32_to_keysym(ch.charCodeAt(0))'
if old_call in s:
    s = s.replace(old_call, 'xkb_utf32_to_keysym(ch.charCodeAt(0))', 1)

open(p, 'w', encoding='utf-8').write(s)
print('printer.js patched')
PY
fi

# ---------------------------------------------------------------------------
# 4) 用适配版视频脚本替换上游版本
# ---------------------------------------------------------------------------
if [ -f "$PATCH_DIR/kvmd-video.sh" ]; then
    log "替换 lib/kvmd-video.sh"
    cp "$PATCH_DIR/kvmd-video.sh" lib/kvmd-video.sh
    chmod +x lib/kvmd-video.sh
else
    die "找不到 $PATCH_DIR/kvmd-video.sh"
fi

# ---------------------------------------------------------------------------
# 5) 校验补丁确实生效
# ---------------------------------------------------------------------------
log "校验补丁"
grep -q "GENERIC" src/common/enums.js || die "enums.js 补丁未生效"
grep -q "hasV4L2Capture" src/common/tool.js || die "tool.js 补丁未生效"
grep -q "'generic'" src/modules/update/app_default_config.js || die "app_default_config.js 补丁未生效"
grep -q "isGeneric" src/modules/update/app_default_config.js || die "二进制路径补丁未生效"
grep -q "pick_capture_device" lib/kvmd-video.sh || die "kvmd-video.sh 未被替换"

# printer.js 必须已经脱离 ffi-napi：该模块在 Node 20 上根本编译不出来，
# 只要还有一处 import 残留，容器启动就会在加载期崩溃
grep -q "koffi.load('libxkbcommon" src/modules/hid/printer.js \
    || die "printer.js 的 koffi 补丁未生效"
# 只匹配真正的 import/require，注释里提到 ffi-napi 不算引用
if grep -qE "from 'ffi-napi'|require\('ffi-napi'\)" src/modules/hid/printer.js; then
    die "printer.js 仍引用 ffi-napi"
fi

# device-tree 读取必须容错：这一行在模块加载期执行，
# 没有 device-tree 的环境会直接崩溃
grep -q "modelOutput = ''" src/modules/update/app_default_config.js \
    || die "app_default_config.js 的 device-tree 容错未生效"
grep -q "let modelOutput = '';" src/common/tool.js \
    || die "tool.js 的 device-tree 容错未生效"

# JS 语法检查（node 已在镜像中）
node --check src/common/tool.js || die "tool.js 语法错误"
node --check src/common/enums.js || die "enums.js 语法错误"
node --check src/modules/update/app_default_config.js || die "app_default_config.js 语法错误"
node --check src/modules/hid/printer.js || die "printer.js 语法错误"
bash -n lib/kvmd-video.sh || die "kvmd-video.sh 语法错误"

log "全部补丁应用成功"
