#!/bin/bash
#
# 逐个编译「没有预编译产物」的原生模块，报告成功/失败原因。
#
# 关注点：这些模块在 armhf + Debian trixie 的 Node 20 上到底能不能编译。
# 不能编的模块，需要决定是改用它法（替换实现 / 裁剪 import）还是放弃功能。

set -u
cd /src/blikvm

echo "node $(node -v)  npm $(npm -v)  napi $(node -e 'console.log(process.versions.napi)')"
echo

# 先把所有想验证的模块列出来：先看每个包有没有预编译产物
echo "=== 各模块是否自带预编译产物 ==="
for m in bcrypt serialport i2c-bus evdev unix-dgram ffi-napi ref-napi cpu-features; do
    dir="node_modules/$m"
    [ -d "$dir" ] || { echo "$m: 未安装"; continue; }
    pre=$(find "$dir" -name '*.node' -type f 2>/dev/null | head -1)
    gyp=$([ -f "$dir/binding.gyp" ] && echo yes || echo no)
    if [ -n "$pre" ]; then
        echo "$m: 自带 .node ($(basename "$pre")), binding.gyp=$gyp"
    else
        echo "$m: 无 .node, binding.gyp=$gyp"
    fi
done

echo
echo "=== 逐个编译 ==="
declare -A RESULT

for m in unix-dgram ffi-napi ref-napi cpu-features; do
    dir="node_modules/$m"
    if [ ! -d "$dir" ]; then
        RESULT[$m]="SKIP 未安装"
        continue
    fi
    echo "--- $m ---"
    # 限时，避免某个模块把流水线卡死
    if out=$( cd "$dir" && timeout 420 node-gyp rebuild 2>&1 ); then
        node_file=$(find "$dir" -name '*.node' -type f 2>/dev/null | head -1)
        if [ -n "$node_file" ]; then
            RESULT[$m]="OK   $(basename "$node_file")"
            echo "OK: $node_file"
        else
            RESULT[$m]="WARN 编译成功但无 .node"
        fi
    else
        # 只留下能说明原因的行，避免日志刷屏
        reason=$(echo "$out" | grep -iE "error:|fatal error|not supported|No such file" | head -3 | tr '\n' ' ')
        [ -n "$reason" ] || reason=$(echo "$out" | tail -3 | tr '\n' ' ')
        RESULT[$m]="FAIL $reason"
        echo "FAIL: $reason"
    fi
done

echo
echo "=== 汇总 ==="
for m in unix-dgram ffi-napi ref-napi cpu-features; do
    printf '%-14s %s\n' "$m" "${RESULT[$m]:-UNKNOWN}"
done

echo
echo "=== 编译成功后能否 require ==="
for m in unix-dgram ffi-napi ref-napi; do
    if node -e "require('$m')" 2>/dev/null; then
        echo "$m: require OK"
    else
        echo "$m: require 失败 -> $(node -e "try{require('$m')}catch(e){console.log(e.message.split('\n')[0])}" 2>&1 | head -1)"
    fi
done
