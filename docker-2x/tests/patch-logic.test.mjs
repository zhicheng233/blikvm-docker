// 验证补丁逻辑：模拟 OneCloud 环境（无 device-tree 匹配、有 /dev/video*）
// 这里只测试纯逻辑分支，不依赖真实硬件。
import fs from 'fs';
import { spawn } from 'node:child_process';

const HardwareType = { UNKNOWN: 0, PI4B: 1, CM4: 2, MangoPi: 3, BliKVMV5CM4: 4, GENERIC: 5 };

// 复刻补丁后的 hasV4L2Capture
function hasV4L2Capture(devEntries) {
  try {
    const nodes = devEntries.filter((n) => /^video\d+$/.test(n));
    return nodes.length > 0;
  } catch (e) {
    return false;
  }
}

// 复刻补丁后的 getHardwareType 判断链（不含 execSync）
function classify(modelOutput, devEntries) {
  const pi4bSys = 'Raspberry Pi 4 Model B';
  const mangoPiSys = 'MangoPi Mcore';
  const piCM4Sys = 'Raspberry Pi Compute Module 4';
  let t = HardwareType.UNKNOWN;
  if (modelOutput.includes(pi4bSys)) t = HardwareType.PI4B;
  else if (modelOutput.includes(mangoPiSys)) t = HardwareType.MangoPi;
  else if (modelOutput.includes(piCM4Sys)) t = HardwareType.CM4;
  else if (hasV4L2Capture(devEntries)) t = HardwareType.GENERIC;
  return t;
}

const cases = [
  { name: 'OneCloud + USB 采集卡', model: 'Xunlei OneCloud', dev: ['video0','video1','null','zero'], want: 'GENERIC' },
  { name: 'OneCloud 无采集卡',      model: 'Xunlei OneCloud', dev: ['null','zero'],                 want: 'UNKNOWN' },
  { name: 'Pi4',                   model: 'Raspberry Pi 4 Model B Rev 1.4', dev: ['video0'],      want: 'PI4B' },
  { name: 'CM4',                   model: 'Raspberry Pi Compute Module 4', dev: ['video0'],       want: 'CM4' },
  { name: 'MangoPi',               model: 'MangoPi Mcore', dev: ['video0'],                       want: 'MangoPi' },
  { name: '无 device-tree + 采集卡', model: '', dev: ['video0'],                                    want: 'GENERIC' },
];

const nameOf = (v) => Object.keys(HardwareType).find((k) => HardwareType[k] === v);

let failed = 0;
for (const c of cases) {
  const got = nameOf(classify(c.model, c.dev));
  const ok = got === c.want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${c.name.padEnd(28)} -> ${got} (期望 ${c.want})`);
}

// 验证视频脚本的分辨率决策逻辑
function resolutionArgs(envRes, cfgRes) {
  const res = envRes || cfgRes;
  if (res && res !== 'native') return [`--resolution=${res}`];
  return [];
}
console.log('');
const resCases = [
  { env: '', cfg: 'native',      want: 0, desc: '默认直出' },
  { env: '', cfg: '1920x1080',   want: 1, desc: '配置指定则缩放' },
  { env: '1280x720', cfg: 'native', want: 1, desc: '环境变量覆盖' },
  { env: 'native', cfg: '1920x1080', want: 0, desc: '显式 native 直出' },
];
for (const c of resCases) {
  const got = resolutionArgs(c.env, c.cfg).length;
  const ok = got === c.want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  分辨率 ${c.desc.padEnd(20)} -> ${got === 1 ? '缩放' : '直出'}`);
}

// ---------------------------------------------------------------------------
// 二进制路径决策
//
// 上游把 ustreamer/janus/kvmd-main 的路径写成 ./lib/<board>/...，
// 只有 pi / h616 两套预编译产物。通用板必须回落到系统 PATH 里的命令名，
// 否则视频脚本收到的是一个不存在的 ./lib/generic/ustreamer.bin 并 exit 1。
// 这是真机启动时实际踩到的坑，不是假想问题。
// ---------------------------------------------------------------------------
function videoBin(hardware) {
  const isGeneric = hardware === 'generic';
  return isGeneric ? 'ustreamer' : `./lib/${hardware}/ustreamer.bin`;
}

function janusBin(hardware) {
  const isGeneric = hardware === 'generic';
  return isGeneric ? '' : `./lib/${hardware}/janus`;
}

console.log('');
const binCases = [
  { hw: 'generic', wantVideo: 'ustreamer',              wantJanus: '',  desc: '通用板用系统 ustreamer' },
  { hw: 'pi',      wantVideo: './lib/pi/ustreamer.bin', wantJanus: './lib/pi/janus', desc: 'Pi 用预编译产物' },
  { hw: 'h616',    wantVideo: './lib/h616/ustreamer.bin', wantJanus: './lib/h616/janus', desc: 'H616 用预编译产物' },
];
for (const c of binCases) {
  const v = videoBin(c.hw);
  const j = janusBin(c.hw);
  const ok = v === c.wantVideo && j === c.wantJanus;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  二进制路径 ${c.desc.padEnd(22)} -> ${v || '(空)'}`);
}

// 通用板绝不能指向 lib/generic 下不存在的文件
if (videoBin('generic').includes('lib/generic')) {
  failed++;
  console.log('FAIL  通用板路径仍指向 lib/generic');
}

// ---------------------------------------------------------------------------
// device-tree 读取容错
//
// getHardwareTypeForConfig() 在模块加载期执行 execSync，
// 没有 /proc/device-tree 时必须降级为通用板而不是抛异常。
// ---------------------------------------------------------------------------
function classifyForConfig(modelOutput) {
  const pi4bSys = 'Raspberry Pi 4 Model B';
  const mangoPiSys = 'MangoPi Mcore';
  const piCM4Sys = 'Raspberry Pi Compute Module 4';
  if (modelOutput.includes(pi4bSys) || modelOutput.includes(piCM4Sys)) return 'pi';
  if (modelOutput.includes(mangoPiSys)) return 'h616';
  return 'generic';
}

console.log('');
const cfgCases = [
  { model: 'Xunlei OneCloud', want: 'generic', desc: 'OneCloud' },
  { model: '', want: 'generic', desc: '无 device-tree（容器）' },
  { model: 'Raspberry Pi 4 Model B Rev 1.4', want: 'pi', desc: 'Pi4' },
  { model: 'MangoPi Mcore', want: 'h616', desc: 'MangoPi' },
];
for (const c of cfgCases) {
  const got = classifyForConfig(c.model);
  const ok = got === c.want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  默认配置 ${c.desc.padEnd(24)} -> ${got}`);
}

// ---------------------------------------------------------------------------
// printer.js 的 FFI 后端替换
//
// 上游在模块加载期就用 ffi-napi 绑定 libxkbcommon，而 ffi-napi 在 Node 20
// 上编译失败（NAPI 的 node_api_basic_env 变更），CI 探测已确认。补丁把它
// 换成 koffi。这里复刻同样的三次替换，并确认幂等与无残留。
// ---------------------------------------------------------------------------
const PRINTER_FIXTURE = `import ffi from 'ffi-napi';
import ref from 'ref-napi';
import { SymmapModifiers, getSysmap } from './keysym.js';

// 定义 XKB 字符串类型
const uint32 = ref.types.uint32;

// 加载 xkbcommon 库
const libxkbcommon = ffi.Library('libxkbcommon', {
    'xkb_utf32_to_keysym': ['uint32', ['uint32']], // xkb_utf32_to_keysym 函数
});

const chToKeysym = (ch) => {
    return libxkbcommon.xkb_utf32_to_keysym(ch.charCodeAt(0));
};
`;

function patchPrinter(s) {
  const oldImports = "import ffi from 'ffi-napi';\nimport ref from 'ref-napi';\n";
  const newImports = "import koffi from 'koffi';\n";
  if (s.includes(oldImports)) {
    s = s.replace(oldImports, newImports);
  } else if (!s.includes(newImports)) {
    throw new Error('import 锚点缺失');
  }

  const oldLib = `// 定义 XKB 字符串类型
const uint32 = ref.types.uint32;

// 加载 xkbcommon 库
const libxkbcommon = ffi.Library('libxkbcommon', {
    'xkb_utf32_to_keysym': ['uint32', ['uint32']], // xkb_utf32_to_keysym 函数
});
`;
  const newLib = `const libxkbcommon = koffi.load('libxkbcommon.so.0');
const xkb_utf32_to_keysym = libxkbcommon.func('uint32 xkb_utf32_to_keysym(uint32)');
`;
  if (s.includes(oldLib)) {
    s = s.replace(oldLib, newLib);
  } else if (!s.includes("koffi.load('libxkbcommon")) {
    throw new Error('绑定块锚点缺失');
  }

  const oldCall = 'libxkbcommon.xkb_utf32_to_keysym(ch.charCodeAt(0))';
  if (s.includes(oldCall)) {
    s = s.replace(oldCall, 'xkb_utf32_to_keysym(ch.charCodeAt(0))');
  }
  return s;
}

console.log('');
const patched = patchPrinter(PRINTER_FIXTURE);
const patchedTwice = patchPrinter(patched);

const printerChecks = [
  { desc: '移除 ffi-napi import',   ok: !patched.includes("from 'ffi-napi'") },
  { desc: '移除 ref-napi import',   ok: !patched.includes("from 'ref-napi'") },
  { desc: '移除 ref.types.uint32',  ok: !patched.includes('ref.types') },
  { desc: '移除 ffi.Library 调用',  ok: !patched.includes('ffi.Library') },
  { desc: '注释不算引用（只查 import/require）', ok: !/from 'ffi-napi'|require\('ffi-napi'\)/.test(patched) },
  { desc: '引入 koffi',             ok: patched.includes("from 'koffi'") },
  { desc: 'koffi 绑定 libxkbcommon', ok: patched.includes("koffi.load('libxkbcommon.so.0')") },
  { desc: '声明 xkb_utf32_to_keysym', ok: patched.includes('const xkb_utf32_to_keysym =') },
  { desc: '调用点已改写',           ok: patched.includes('xkb_utf32_to_keysym(ch.charCodeAt(0))') && !patched.includes('libxkbcommon.xkb_utf32_to_keysym') },
  { desc: '保留 keysym.js import',  ok: patched.includes("from './keysym.js'") },
  { desc: '幂等',                   ok: patched === patchedTwice },
];
for (const c of printerChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  printer.js ${c.desc}`);
}

// ---------------------------------------------------------------------------
// server.js：ESM 下没有 __dirname
//
// 上游用 pkg 打包成 CJS，所以 src/server/server.js 直接用了 CJS 的 __dirname
// 定位前端静态目录。本方案以 ESM 跑源码，该全局不存在，getRootPath() 首次
// 被调用就 ReferenceError。补丁从 import.meta.url 还原它。
// ---------------------------------------------------------------------------
const SERVER_FIXTURE = `import express from 'express';
import path from 'path';

function getRootPath() {
  return __dirname;
}
`;

function patchServer(s) {
  const anchor = "import path from 'path';";
  const inject = `import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));`;
  if (s.includes('fileURLToPath(import.meta.url)')) return s;
  if (!s.includes(anchor)) throw new Error('path import 锚点缺失');
  return s.replace(anchor, inject);
}

const patchedServer = patchServer(SERVER_FIXTURE);
const serverChecks = [
  { desc: '注入 fileURLToPath', ok: patchedServer.includes("import { fileURLToPath } from 'url';") },
  { desc: '还原 __dirname',     ok: patchedServer.includes('const __dirname = path.dirname(fileURLToPath(import.meta.url));') },
  { desc: '保留原有逻辑',       ok: patchedServer.includes('return __dirname;') },
  { desc: '幂等',               ok: patchServer(patchedServer) === patchedServer },
  { desc: '锚点缺失时抛错',     ok: (() => { try { patchServer('no anchor here'); return false; } catch { return true; } })() },
];
console.log('');
for (const c of serverChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  server.js ${c.desc}`);
}

// ---------------------------------------------------------------------------
// config/app.json：初始配置里的二进制路径
//
// 这是最容易漏的一处：entrypoint 首次启动就把 config/*.json 复制到
// /data/config，而 app_default_config.js 只在版本升级时补缺失字段。
// 所以真正生效的初始值来自 config/app.json 本身。
// ---------------------------------------------------------------------------
function patchAppConfig(cfg) {
  const out = JSON.parse(JSON.stringify(cfg));
  out.video.bin = 'ustreamer';
  out.video.recordBin = '';
  out.video.resolution = 'native';
  out.janus = { bin: '', configsFolder: '', pluginsFolder: '' };
  out.kvmd = { bin: '' };
  out.atx.isActive = false;
  return out;
}

const APP_FIXTURE = {
  version: 10,
  deviceVersion: 'BliKVM 2.x',
  video: { bin: './lib/pi/ustreamer.bin', recordBin: './lib/pi/record', resolution: '1920x1080' },
  janus: { bin: './lib/pi/janus', configsFolder: './lib/pi/janus-configs', pluginsFolder: './lib/pi/janus-plugins' },
  kvmd: { bin: './lib/pi/kvmd-main' },
  atx: { isActive: true },
};

const patchedCfg = patchAppConfig(APP_FIXTURE);
const cfgJson = JSON.stringify(patchedCfg);
const appChecks = [
  { desc: '视频用系统 ustreamer',   ok: patchedCfg.video.bin === 'ustreamer' },
  { desc: '默认分辨率直出',         ok: patchedCfg.video.resolution === 'native' },
  { desc: '关闭录制二进制',         ok: patchedCfg.video.recordBin === '' },
  { desc: 'janus 置空',             ok: patchedCfg.janus.bin === '' },
  { desc: 'kvmd-main 置空',         ok: patchedCfg.kvmd.bin === '' },
  { desc: 'ATX 标记为不可用',       ok: patchedCfg.atx.isActive === false },
  { desc: '无 lib/<board>/ 残留',   ok: !/"(bin|recordBin)": "\.\/lib\//.test(cfgJson) },
  { desc: '不修改输入对象',         ok: APP_FIXTURE.video.bin === './lib/pi/ustreamer.bin' },
];
console.log('');
for (const c of appChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  config/app.json ${c.desc}`);
}

// 默认配置里的 BliSwitch 指向 /dev/ttyUSB0；通用板没有这个串口，
// 每次全新部署都会先初始化失败报错、再把自己关闭。初始值就应为关闭。
function patchSwitchConfig(cfg) {
  const out = JSON.parse(JSON.stringify(cfg));
  out.kvmSwitch.isActive = false;
  return out;
}

const SWITCH_FIXTURE = { version: 1, kvmSwitch: { isActive: true, activeSwitchId: 1, items: [] } };
const patchedSwitch = patchSwitchConfig(SWITCH_FIXTURE);
const switchChecks = [
  { desc: '默认关闭 BliSwitch', ok: patchedSwitch.kvmSwitch.isActive === false },
  { desc: '保留 activeSwitchId', ok: patchedSwitch.kvmSwitch.activeSwitchId === 1 },
  { desc: '不修改输入对象',     ok: SWITCH_FIXTURE.kvmSwitch.isActive === true },
];
console.log('');
for (const c of switchChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  config/switch.json ${c.desc}`);
}

// ---------------------------------------------------------------------------
// index.js：可选子服务
//
// 通用板上 janus / kvmd-main 没有可执行文件（上游只给 aarch64 二进制）。
// 上游对这些服务既没有 .catch()，ATX 又无条件 fs.watch 一个由 kvmd-main
// 创建的状态文件。任一失败都会成为未处理 rejection，Node 20 直接退出。
// ---------------------------------------------------------------------------
function isKvmdMainConfigured(cfg) {
  try {
    return Boolean(cfg && cfg.kvmd && cfg.kvmd.bin);
  } catch (e) {
    return false;
  }
}

const kvmdCases = [
  { desc: '通用板（bin 为空）跳过', cfg: { kvmd: { bin: '' } },  want: false },
  { desc: 'Pi（有 bin）启用',       cfg: { kvmd: { bin: './lib/pi/kvmd-main' } }, want: true },
  { desc: '缺 kvmd 段跳过',         cfg: {},                      want: false },
  { desc: '配置损坏按不可用处理',   cfg: null,                    want: false },
];
console.log('');
for (const c of kvmdCases) {
  let got;
  try { got = isKvmdMainConfigured(c.cfg); } catch { got = false; }
  const ok = got === c.want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  index.js ${c.desc.padEnd(20)} -> ${got ? '启动' : '跳过'}`);
}

// spawn('') 会同步抛 ERR_INVALID_ARG_VALUE，所以空 bin 必须在调用前拦下，
// 不能指望 .catch() 兜底（异常发生在 Promise executor 里）。
const emptySpawnThrows = (() => {
  try {
    spawn('');
    return false;
  } catch (e) {
    return e.code === 'ERR_INVALID_ARG_VALUE';
  }
})();
if (!emptySpawnThrows) failed++;
console.log(`${emptySpawnThrows ? 'PASS' : 'FAIL'}  index.js spawn('') 确实同步抛错（故需前置跳过）`);

// ---------------------------------------------------------------------------
// 前端补丁：诊断浮层退出 Vuetify 全局 z-index 栈
//
// 没插采集卡时，「未检测到信号」浮层一直挂在 Vuetify 的全局 overlay 栈上，
// 它的 z-index 取自应用的 zIndex.diagnostics = 700。Vuetify 的 useStack 会给
// 之后打开的菜单取「栈顶 + 10」= 710，而嵌套 v-layout 的抽屉算出来是 904。
// 710 < 904 → 抽屉里的下拉菜单整块被抽屉盖住，看起来就是「点了没反应」。
//
// 补丁让这个纯展示浮层不参与全局栈，菜单回落到自己的默认值。
// ---------------------------------------------------------------------------
const DIAG_FIXTURE = `<template>
  <v-overlay
    :model-value="showDiagnostics"
    :opacity="0"
    contained
    content-class="d-flex flex-column align-center justify-end w-100 h-100"
  >
    <v-spacer />
  </v-overlay>
</template>
`;

function patchDiagnostics(raw) {
  if (raw.includes('_disable-global-stack')) return raw;
  const lines = raw.split('\n');
  const at = lines.findIndex((l) => l.includes(':opacity="0"'));
  if (at === -1) throw new Error('锚点缺失');
  const indent = lines[at].match(/^[ \t]*/)[0];
  lines.splice(at + 1, 0, `${indent}:_disable-global-stack="true"`);
  return lines.join('\n');
}

const diagPatched = patchDiagnostics(DIAG_FIXTURE);
const diagTwice = patchDiagnostics(diagPatched);
const diagLines = diagPatched.split('\n');
const diagChecks = [
  { desc: '注入 _disable-global-stack', ok: diagPatched.includes(':_disable-global-stack="true"') },
  {
    desc: '落在 v-overlay 标签内',
    ok: (() => {
      const open = diagLines.findIndex((l) => l.trim().startsWith('<v-overlay'));
      const close = diagLines.findIndex((l) => l.trim() === '>');
      const attr = diagLines.findIndex((l) => l.includes('_disable-global-stack'));
      return open !== -1 && close !== -1 && attr > open && attr < close;
    })(),
  },
  { desc: '保持缩进一致', ok: diagLines.find((l) => l.includes('_disable-global-stack')).startsWith('    :') },
  { desc: '幂等', ok: diagPatched === diagTwice },
  { desc: '只注入一次', ok: diagLines.filter((l) => l.includes('_disable-global-stack')).length === 1 },
  { desc: '不改动其他内容', ok: diagPatched.includes(':model-value="showDiagnostics"') && diagPatched.includes('contained') },
  { desc: '锚点缺失时抛错', ok: (() => { try { patchDiagnostics('<template>\n  <v-overlay>\n'); return false; } catch { return true; } })() },
];
console.log('');
for (const c of diagChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  AppDiagnosticsSignal.vue ${c.desc}`);
}

// ---------------------------------------------------------------------------
// 前端补丁：语言下拉的中文标签
//
// 上游把 zh 的 label 写成「中国人」，下拉里看着像选国籍而不是选语言，
// 中文用户很容易以为没有中文可选。
// ---------------------------------------------------------------------------
function patchLangLabel(raw) {
  return raw.replace("label: '中国人'", "label: '中文'");
}

const langFixture = "  { language: 'zh', ocr: 'chi_sim', label: '中国人' },";
const langPatched = patchLangLabel(langFixture);
const langChecks = [
  { desc: '标签改为中文',   ok: langPatched.includes("label: '中文'") },
  { desc: '无中国人残留',   ok: !langPatched.includes('中国人') },
  { desc: '保留 language', ok: langPatched.includes("language: 'zh'") },
  { desc: '保留 ocr',      ok: langPatched.includes("ocr: 'chi_sim'") },
  { desc: '幂等',          ok: patchLangLabel(langPatched) === langPatched },
];
console.log('');
for (const c of langChecks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? 'PASS' : 'FAIL'}  useLanguage.js ${c.desc}`);
}

console.log(`\n${failed === 0 ? '全部通过' : failed + ' 项失败'}`);
process.exit(failed === 0 ? 0 : 1);
