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

console.log(`\n${failed === 0 ? '全部通过' : failed + ' 项失败'}`);
process.exit(failed === 0 ? 0 : 1);
