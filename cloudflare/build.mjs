// 构建脚本：把 src/views/{landing,admin}.html 注入 src/index.js 的占位符，输出 dist/worker.js
// 这样开发时 HTML 独立可维护，部署时再内联进 Worker bundle（Worker 运行时不能 fs 读文件）。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const src = join(__dirname, 'src');

// 全仓唯一版本源：根目录 VERSION。所有页面必须含 {{APP_VERSION}} 占位符，构建时统一注入
const version = readFileSync(join(__dirname, '..', 'VERSION'), 'utf8').trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  console.error('✗ VERSION 格式不合法：' + version + '（应为 x.y.z）');
  process.exit(1);
}
const injectVersion = (name, raw) => {
  if (!raw.includes('{{APP_VERSION}}')) {
    console.error(`✗ ${name}.html 缺少 {{APP_VERSION}} 占位符：版本一致性规则要求所有页面显示当前版本`);
    process.exit(1);
  }
  return raw.replaceAll('{{APP_VERSION}}', version);
};

// 全仓唯一显示时区源：根目录 TIMEZONE（跳过 # 注释与空行）。数据层仍存 UTC ISO 8601 Z。
const tz = readFileSync(join(__dirname, '..', 'TIMEZONE'), 'utf8')
  .split('\n').map(l => l.trim()).find(l => l && !l.startsWith('#'));
if (!tz) { console.error('✗ TIMEZONE 为空：必须写一行 IANA 时区名，如 Asia/Shanghai'); process.exit(1); }
try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); }
catch (e) { console.error('✗ TIMEZONE 不是合法 IANA 时区名：' + tz); process.exit(1); }
const timeJs = readFileSync(join(src, 'views', 'time.js'), 'utf8').replaceAll('__DISPLAY_TZ__', tz);
if (timeJs.includes('__DISPLAY_TZ__')) { console.error('✗ time.js 时区占位符未替换'); process.exit(1); }
const injectTime = (name, raw) => {
  if (name === 'admin' && !raw.includes('{{TIME_FORMAT_JS}}')) {
    console.error('✗ admin.html 缺少 {{TIME_FORMAT_JS}}：时间显示必须走统一格式化函数');
    process.exit(1);
  }
  return raw.replaceAll('{{TIME_FORMAT_JS}}', timeJs).replaceAll('{{DISPLAY_TZ}}', tz);
};
const landing = injectTime('landing', injectVersion('landing', readFileSync(join(src, 'views', 'landing.html'), 'utf8')));
const admin = injectTime('admin', injectVersion('admin', readFileSync(join(src, 'views', 'admin.html'), 'utf8')));
for (const [name, raw] of [['landing', landing], ['admin', admin]]) {
  if (raw.includes('{{TIME_FORMAT_JS}}') || raw.includes('{{DISPLAY_TZ}}')) {
    console.error(`✗ ${name}.html 仍有未替换的时区占位符`); process.exit(1);
  }
}
let worker = readFileSync(join(src, 'index.js'), 'utf8');

// JSON.stringify 会转义 HTML 内的双引号/换行，注入为合法 JS 字符串字面量
worker = worker
  .replace('__LANDING_HTML__', JSON.stringify(landing))
  .replace('__ADMIN_HTML__', JSON.stringify(admin));

if (worker.includes('__LANDING_HTML__') || worker.includes('__ADMIN_HTML__')) {
  console.error('✗ 注入失败：占位符未被替换，请检查 src/index.js 是否含 __LANDING_HTML__ / __ADMIN_HTML__');
  process.exit(1);
}

const outDir = join(__dirname, 'dist');
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'worker.js'), worker);
console.log(`✓ build 完成 -> dist/worker.js  (v${version}; 显示时区 ${tz}; landing ${landing.length}B, admin ${admin.length}B)`);
