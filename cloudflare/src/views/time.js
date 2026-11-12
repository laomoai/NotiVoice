// NotiVoice 统一时间格式化（显示层）。由 cloudflare/build.mjs 注入到页面 <script> 顶部。
// 显示时区的唯一来源是仓库根目录 TIMEZONE：构建时把时区字面量注入 NV_DISPLAY_TZ。
// 数据层（D1 / API / 本地 SQLite）始终保存 UTC ISO 8601（带 Z）；只有给人看时才按此时区转换。
// 本文件独立成文件，便于 scripts/test-timezone.mjs 直接跑真实代码做黄金用例测试。
const NV_DISPLAY_TZ = '__DISPLAY_TZ__';

// 页面标注用：例 "Asia/Shanghai（UTC+8）"。offset 由 Intl 动态计算，不写死，改时区自动跟随。
function nvZoneLabel() {
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: NV_DISPLAY_TZ, timeZoneName: 'shortOffset'
    }).formatToParts(new Date());
    const raw = parts.find(p => p.type === 'timeZoneName')?.value || '';
    const off = raw.replace(/^GMT/, 'UTC');
    return NV_DISPLAY_TZ + '（' + (off || 'UTC') + '）';
  } catch (e) {
    return NV_DISPLAY_TZ;
  }
}

// 把 UTC 时戳格式化为 YYYY-MM-DD HH:mm:ss（显示时区）。
// 兼容：带 Z / 带毫秒 / 带 ±HH:MM 偏移 / 历史数据 "YYYY-MM-DD HH:MM:SS"（按 UTC 解释）。
function fmt(s) {
  if (s === null || s === undefined || s === '') return '';
  const raw = String(s).trim();
  let iso = raw.replace(' ', 'T');
  if (!/(Z|[+-]\d{2}:?\d{2})$/i.test(iso)) iso += 'Z';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return raw.replace('T', ' ').replace(/Z$/, '').slice(0, 19);
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: NV_DISPLAY_TZ,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    hourCycle: 'h23'
  }).formatToParts(d);
  const g = t => parts.find(p => p.type === t)?.value || '';
  return g('year') + '-' + g('month') + '-' + g('day') + ' '
       + g('hour') + ':' + g('minute') + ':' + g('second');
}
