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
const landing = injectVersion('landing', readFileSync(join(src, 'views', 'landing.html'), 'utf8'));
const admin = injectVersion('admin', readFileSync(join(src, 'views', 'admin.html'), 'utf8'));
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
console.log(`✓ build 完成 -> dist/worker.js  (v${version}; landing ${landing.length}B, admin ${admin.length}B)`);
