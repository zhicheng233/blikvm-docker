#!/bin/bash
#
# 在构建期对上游 blikvm-web-client 源码打补丁。
#
# 设计原则与 apply-patches.sh 一致：
#   - 幂等：重复执行不会重复打补丁
#   - 可失败：上游结构变化导致补丁打不上时立即退出（fail closed），
#     不允许产出「看起来构建成功、实际行为有问题」的前端
#
# 只用 POSIX 工具（awk/sed/grep），不依赖 node/python，避免构建机差异。
#
# 用法：apply-web-patches.sh <前端源码根目录>
#
# 本文件以 GPL-3.0 发布（与上游 blikvm-web-client 一致）。

set -euo pipefail

SRC="${1:-/web}"
cd "$SRC"

log() { echo "[web-patch] $*"; }
die() { echo "[web-patch] ERROR: $*" >&2; exit 1; }

DIAG_VUE=src/components/AppDiagnosticsSignal.vue
LANG_JS=src/composables/useLanguage.js

[ -f "$DIAG_VUE" ] || die "找不到 $DIAG_VUE，前端源码目录不对: $SRC"
[ -f "$LANG_JS" ]  || die "找不到 $LANG_JS"

# ---------------------------------------------------------------------------
# 1) AppDiagnosticsSignal.vue：诊断浮层退出 Vuetify 全局 z-index 栈
# ---------------------------------------------------------------------------
# 现象：设置面板（左侧抽屉）里的下拉框点了没反应，看不到任何选项。
#
# 成因：
#   - 该浮层（「未检测到信号」提示）用应用自定义的 z-index 700
#     （src/styles/zIndex.js 的 diagnostics）；
#   - Vuetify 的 useStack 会给之后打开的 overlay 取「栈顶 + 10」，
#     于是下拉菜单变成 710；
#   - 页面是嵌套 v-layout，抽屉算出来的 z-index 是 904。
#   710 < 904，菜单整块落在抽屉底下 —— 视觉上就是「点了没反应」。
#
# 只要没插采集卡（诊断浮层一直显示），抽屉内所有下拉菜单都会中招。
#
# 修法：让这个纯展示用的浮层不参与全局栈，后续菜单回落到默认 z-index。
if grep -q "_disable-global-stack" "$DIAG_VUE"; then
    log "AppDiagnosticsSignal.vue 已打过补丁，跳过"
else
    log "打补丁: AppDiagnosticsSignal.vue 退出全局 z-index 栈"
    awk '
        !done && /:opacity="0"/ {
            print
            match($0, /^[ \t]*/)
            indent = substr($0, 1, RLENGTH)
            print indent ":_disable-global-stack=\"true\""
            done = 1
            next
        }
        { print }
        END { if (!done) exit 3 }
    ' "$DIAG_VUE" > "$DIAG_VUE.tmp" || { rm -f "$DIAG_VUE.tmp"; die "$DIAG_VUE: 找不到 :opacity=\"0\" 锚点，上游结构可能已变化"; }
    mv "$DIAG_VUE.tmp" "$DIAG_VUE"
fi
grep -q "_disable-global-stack" "$DIAG_VUE" || die "$DIAG_VUE 补丁未生效"

# ---------------------------------------------------------------------------
# 2) useLanguage.js：语言下拉里的中文标签写错了
# ---------------------------------------------------------------------------
# 上游把 zh 的 label 写成了「中国人」（应为「中文」），下拉里像是选「中国人」
# 而不是选语言，容易被误认为没有中文可选项。
if grep -q "label: '中文'" "$LANG_JS"; then
    log "useLanguage.js 中文标签已修正，跳过"
else
    log "打补丁: useLanguage.js 语言标签 中国人 -> 中文"
    sed -i "s/label: '中国人'/label: '中文'/" "$LANG_JS"
fi
grep -q "label: '中文'" "$LANG_JS" || die "useLanguage.js 中文标签补丁未生效"
if grep -q "label: '中国人'" "$LANG_JS"; then
    die "useLanguage.js 仍残留「中国人」标签"
fi

log "前端补丁全部就绪"
