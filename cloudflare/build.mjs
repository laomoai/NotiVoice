// 构建脚本：把 src/views/{landing,admin}.html 注入 src/index.js 的占位符，输出 dist/worker.js
// 这样开发时 HTML 独立可维护，部署时再内联进 Worker bundle（Worker 运行时不能 fs 读文件）。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const src = join(__dirname, 'src');

const landing = readFileSync(join(src, 'views', 'landing.html'), 'utf8');
const admin = readFileSync(join(src, 'views', 'admin.html'), 'utf8');
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
console.log('✓ build 完成 -> dist/worker.js  (landing ' + landing.length + 'B, admin ' + admin.length + 'B)');
