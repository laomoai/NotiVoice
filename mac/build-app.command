#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v swift >/dev/null 2>&1; then
  echo "未找到 Swift。请先安装 Xcode 或 Xcode Command Line Tools：xcode-select --install"
  read -r -p "按回车退出...";exit 1
fi
# 常规构建失败时（如受限/嵌套沙箱环境禁用 SwiftPM 清单沙箱）自动降级重试
if ! swift build -c release >/tmp/notivoice-build.log 2>&1; then
  echo "常规构建失败，重试：禁用 SwiftPM 清单沙箱"
  cat /tmp/notivoice-build.log
  swift build -c release --disable-sandbox
fi
APP="$PWD/dist/NotiVoice.app"
REPO="$PWD/.."
# 版本号唯一来源：仓库根目录 VERSION 文件；升级只改那一处，关于页 / Finder 都从 Info.plist 读
if [ ! -f "$REPO/VERSION" ]; then echo "缺少 $REPO/VERSION（全仓唯一版本源）"; exit 1; fi
APP_VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
if ! printf '%s' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then echo "VERSION 格式不合法：${APP_VERSION}（应为 x.y.z）"; exit 1; fi
# 显示时区唯一来源：根目录 TIMEZONE（跳过 # 注释与空行），与 Worker 页面共用同一份配置
if [ ! -f "$REPO/TIMEZONE" ]; then echo "缺少 $REPO/TIMEZONE（全仓唯一显示时区源）"; exit 1; fi
DISPLAY_TZ="$(awk '!/^[[:space:]]*(#|$)/ {gsub(/[[:space:]]/, ""); print; exit}' "$REPO/TIMEZONE")"
if [ -z "$DISPLAY_TZ" ]; then echo "TIMEZONE 为空"; exit 1; fi
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
GIT_COMMIT="$(git -C "$REPO" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then GIT_DIRTY=yes; else GIT_DIRTY=no; fi
# 默认安装/正式版图标（蓝色）；--local 用本地开发版（紫色 + LOCAL 角标）；--no-open 只打包不启动
VARIANT=release
NO_OPEN=0
for arg in "$@"; do
  if [ "$arg" = "--local" ]; then VARIANT=local; fi
  if [ "$arg" = "--no-open" ]; then NO_OPEN=1; fi
done
ICON="$PWD/../assets/logo/NotiVoice-${VARIANT}.icns"
# 图标是发布包的一部分：缺文件直接失败，禁止静默退化为 Finder 的默认白方块
if [ ! -f "$ICON" ]; then
  echo "✗ 缺少图标源文件：$ICON" >&2
  echo "  请补齐 assets/logo 后重新出包（不允许无图标发布）。" >&2
  exit 1
fi
# 干净重建：让 .app 目录自身 mtime 同步更新，Finder 里显示的修改时间才准确
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotiVoice "$APP/Contents/MacOS/NotiVoice"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
if [ ! -s "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "✗ 图标写入失败：AppIcon.icns 为空或不存在" >&2
  exit 1
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotiVoice</string>
<key>CFBundleIdentifier</key><string>cn.lemoai.notivoice</string>
<key>CFBundleName</key><string>NotiVoice</string>
<key>CFBundleDisplayName</key><string>Noti Voice</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>NVGitCommit</key><string>${GIT_COMMIT}</string>
<key>NVBuildTime</key><string>${BUILD_TIME}</string>
<key>NVBuildVariant</key><string>${VARIANT}</string>
<key>NVGitDirty</key><string>${GIT_DIRTY}</string>
<key>NVDisplayTimezone</key><string>${DISPLAY_TZ}</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/NotiVoice"
# 干净重建会换 inode，Finder/IconServices 可能仍显示旧缓存（白色默认方块）；主动重新注册
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then "$LSREG" -force -R -f "$APP" >/dev/null 2>&1 || true; fi
echo "构建完成：${APP}（图标已注册刷新）"
echo "版本 V${APP_VERSION} · build ${BUILD_NUMBER} · 标识 ${GIT_COMMIT} · ${VARIANT} · ${BUILD_TIME} · 时区 ${DISPLAY_TZ} · dirty=${GIT_DIRTY}"
if [ "$NO_OPEN" -eq 0 ]; then open "$APP"; fi
