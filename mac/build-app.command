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
# 版本号唯一来源：升级只改 APP_VERSION；关于页 / Finder 都从 Info.plist 读，禁止在 UI 里写死
APP_VERSION="1.1.2"
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
# 干净重建：让 .app 目录自身 mtime 同步更新，Finder 里显示的修改时间才准确
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotiVoice "$APP/Contents/MacOS/NotiVoice"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "提示：未找到 $ICON，App 将使用系统默认图标"
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
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/NotiVoice"
echo "构建完成：$APP"
echo "版本 V${APP_VERSION} · build ${BUILD_NUMBER} · 标识 ${GIT_COMMIT} · ${VARIANT} · ${BUILD_TIME} · dirty=${GIT_DIRTY}"
if [ "$NO_OPEN" -eq 0 ]; then open "$APP"; fi
