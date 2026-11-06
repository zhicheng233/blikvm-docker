// 验证补丁逻辑：模拟 OneCloud 环境（无 device-tree 匹配、有 /dev/video*）
// 这里只测试纯逻辑分支，不依赖真实硬件。
import fs from 'fs';

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

console.log(`\n${failed === 0 ? '全部通过' : failed + ' 项失败'}`);
process.exit(failed === 0 ? 0 : 1);
