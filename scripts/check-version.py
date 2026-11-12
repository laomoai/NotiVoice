#!/usr/bin/env python3
"""版本一致性门禁：改 VERSION 后必须运行，确保全部文档、页面与构建产物同步。

用法: python3 scripts/check-version.py
规则: 唯一版本源 = 仓库根目录 VERSION；任一锚点漏改 / 残留旧精确版本 / 产物未重建 → 退出码 1。
"""
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
# 显示时区唯一来源：根目录 TIMEZONE（跳过 # 注释与空行）
_tz_lines = [l.strip() for l in (ROOT / "TIMEZONE").read_text(encoding="utf-8").splitlines()
             if l.strip() and not l.strip().startswith("#")]
TZ = _tz_lines[0] if _tz_lines else ""
FAILED = []
CHECKS = 0


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}" + (f"  -> {detail}" if detail else ""))
        FAILED.append(label)


def read(rel):
    p = ROOT / rel
    return p.read_text(encoding="utf-8") if p.exists() else ""


print(f"当前版本: {VERSION}  (唯一版本源: VERSION)")
check("VERSION 格式 x.y.z", bool(re.fullmatch(r"\d+\.\d+\.\d+", VERSION)), VERSION)

# 1) 文档与页面的版本锚点：文档写当前精确版本，页面用占位符（构建时注入）
ANCHORS = [
    ("README.md", f"当前版本：**V{VERSION}**"),
    ("docs/API.md", f"当前版本 V{VERSION}"),
    ("docs/ARCHITECTURE.md", f"当前版本 V{VERSION}"),
    ("docs/TESTING.md", f"适用版本：**V{VERSION}**"),
    ("cloudflare/src/views/landing.html", "v{{APP_VERSION}}"),
    ("cloudflare/src/views/admin.html", "v{{APP_VERSION}}"),
    ("mac/build-app.command", '"$REPO/VERSION"'),
    ("cloudflare/build.mjs", "'..', 'VERSION'"),
]
for rel, needle in ANCHORS:
    text = read(rel)
    check(f"锚点 {rel}", needle in text, f"缺少 {needle!r}" + ("（文件不存在）" if not text else ""))

# 2) CHANGELOG 最新条目必须等于当前版本（历史条目保留，不参与扫描）
chg = read("CHANGELOG.md")
latest = re.search(r"^## (V\d+\.\d+\.\d+)", chg, re.M)
check("CHANGELOG 最新条目", bool(latest) and latest.group(1) == f"V{VERSION}",
      f"期望 ## V{VERSION}，实际 {latest.group(1) if latest else '未找到'}")

# 3) 全仓扫描残留的旧精确版本号（CHANGELOG 历史、依赖锁文件、构建缓存除外）
EXCLUDE_DIRS = {".git", "node_modules", ".build", "dist", "tmp", ".workbuddy", ".wrangler", "design"}
EXCLUDE_FILES = {"CHANGELOG.md", "package-lock.json", "VERSION"}
SCAN_EXT = {".md", ".html", ".js", ".mjs", ".swift", ".command", ".sh", ".py", ".sql", ".toml"}
PAT = re.compile(r"(?<![\d.])(?:[Vv])?(1\.\d+\.\d+)")
stale = []
for p in ROOT.rglob("*"):
    if not p.is_file() or p.suffix not in SCAN_EXT or p.name in EXCLUDE_FILES:
        continue
    if any(part in EXCLUDE_DIRS for part in p.relative_to(ROOT).parts):
        continue
    for n, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        for m in PAT.finditer(line):
            if m.group(1) != VERSION:
                stale.append(f"{p.relative_to(ROOT)}:{n}: {m.group(0)} -> {line.strip()[:100]}")
check("全仓无旧精确版本残留", not stale, "\n       ".join(stale[:20]) + (f"\n       ...共 {len(stale)} 处" if len(stale) > 20 else ""))

# 4) 构建产物必须与 VERSION 一致（防止改了版本号却没重新构建 / 没部署）
app_plist = ROOT / "mac/dist/NotiVoice.app/Contents/Info.plist"
if app_plist.exists():
    info = plistlib.loads(app_plist.read_bytes())
    check("客户端产物 Info.plist", info.get("CFBundleShortVersionString") == VERSION and "NVGitCommit" in info,
          f"CFBundleShortVersionString={info.get('CFBundleShortVersionString')}, 标识={info.get('NVGitCommit')}")
    check("客户端产物显示时区", info.get("NVDisplayTimezone") == TZ,
          f"NVDisplayTimezone={info.get('NVDisplayTimezone')!r}，期望 {TZ!r}")
else:
    check("客户端产物 Info.plist", False, "尚未出包：运行 bash mac/build-app.command --no-open")

worker = ROOT / "cloudflare/dist/worker.js"
if worker.exists():
    w = worker.read_text(encoding="utf-8")
    check("Worker 产物已注入当前版本", f"v{VERSION}" in w and "{{APP_VERSION}}" not in w,
          f"含 v{VERSION}={f'v{VERSION}' in w}, 残留占位符={'{{APP_VERSION}}' in w}")
else:
    check("Worker 产物已注入当前版本", False, "尚未构建：cd cloudflare && npm run build")

# 5) 显示时区一致性：唯一来源 TIMEZONE；注入链路、Worker 产物与客户端 plist 必须用同一值
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
try:
    ZoneInfo(TZ)
    tz_valid = bool(TZ)
except (ZoneInfoNotFoundError, ValueError, TypeError):
    tz_valid = False
check("TIMEZONE 为合法 IANA 时区", tz_valid, f"实际 {TZ!r}")
check("build.mjs 读取 TIMEZONE", "'..', 'TIMEZONE'" in read("cloudflare/build.mjs"))
check("time.js 含时区注入占位符", "__DISPLAY_TZ__" in read("cloudflare/src/views/time.js"))
_admin = read("cloudflare/src/views/admin.html")
check("后台走统一 fmt 注入", "{{TIME_FORMAT_JS}}" in _admin and "function fmt(s){" not in _admin)
_app = read("mac/build-app.command")
check("出包脚本注入客户端时区", "NVDisplayTimezone" in _app and "$REPO/TIMEZONE" in _app)
_w = read("cloudflare/dist/worker.js")
check("Worker 产物时区已注入", bool(TZ) and ("NV_DISPLAY_TZ = '" + TZ + "'") in _w
      and "__DISPLAY_TZ__" not in _w and "{{TIME_FORMAT_JS}}" not in _w, f"TZ={TZ!r}")

print(f"\n===== 结果：{CHECKS - len(FAILED)} 通过 / {len(FAILED)} 失败 =====")
if FAILED:
    print("版本未同步，禁止宣称发布完成。失败项：" + ", ".join(FAILED))
    sys.exit(1)
print("ALL PASS：文档、页面与产物版本一致。")
