#!/usr/bin/env node
// 显示时区格式化回归：直接执行 cloudflare/src/views/time.js 的真实代码（不复制逻辑）。
// 用法: node scripts/test-timezone.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(join(root, 'cloudflare', 'src', 'views', 'time.js'), 'utf8');
const tzFile = readFileSync(join(root, 'TIMEZONE'), 'utf8');
const TZ = tzFile.split('\n').map(l => l.trim()).find(l => l && !l.startsWith('#'));

function load(zone) {
  const ctx = { Intl, Date, console };
  vm.createContext(ctx);
  vm.runInContext(src.replaceAll('__DISPLAY_TZ__', zone), ctx);
  return ctx;
}

let pass = 0, fail = 0;
function eq(label, actual, expected) {
  if (actual === expected) { pass++; console.log(`[PASS] ${label}`); }
  else { fail++; console.log(`[FAIL] ${label} -> 实际 ${JSON.stringify(actual)}，期望 ${JSON.stringify(expected)}`); }
}
function ok(label, cond) { eq(label, !!cond, true); }

const c = load(TZ);
eq('配置时区为 Asia/Shanghai（默认北京时间）', TZ, 'Asia/Shanghai');
eq('UTC 带 Z -> 北京时间', c.fmt('2026-11-12T01:02:42Z'), '2026-11-12 09:02:42');
eq('UTC 带毫秒 -> 北京时间', c.fmt('2026-11-12T01:02:42.123Z'), '2026-11-12 09:02:42');
eq('历史空格分隔（无 Z，按 UTC 解释）', c.fmt('2026-11-12 01:02:42'), '2026-11-12 09:02:42');
eq('跨日边界', c.fmt('2026-11-11T16:30:00Z'), '2026-11-12 00:30:00');
eq('带偏移的时戳按绝对时刻换算', c.fmt('2026-11-12T10:02:42+01:00'), '2026-11-12 17:02:42');
eq('空字符串', c.fmt(''), '');
eq('null', c.fmt(null), '');
eq('undefined', c.fmt(undefined), '');
ok('非法值不崩溃且原样兜底', c.fmt('not-a-date') === 'not-a-date');
ok('时区标签含 UTC+8', c.nvZoneLabel().includes('UTC+8'));

// 证明「改一处配置就全端跟随」：同一份代码换时区后输出必须改变
const utc = load('UTC');
eq('改成 UTC 配置后不再 +8', utc.fmt('2026-11-12T01:02:42Z'), '2026-11-12 01:02:42');
ok('UTC 标签', utc.nvZoneLabel().includes('UTC'));
const ny = load('America/New_York');
eq('冬令时 EST（UTC-5）', ny.fmt('2026-11-12T01:02:42Z'), '2026-11-11 20:02:42');
eq('夏令时 EDT（UTC-4，offset 动态）', ny.fmt('2026-07-12T01:02:42Z'), '2026-07-11 21:02:42');

console.log(`\n===== 结果：${pass} 通过 / ${fail} 失败 =====`);
if (fail) process.exit(1);
console.log('ALL PASS：前后端统一按 TIMEZONE 显示，数据层仍为 UTC。');
