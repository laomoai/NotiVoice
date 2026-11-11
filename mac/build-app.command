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
# 默认安装/正式版图标（蓝色）；bash build-app.command --local 用本地开发版（紫色 + LOCAL 角标）
VARIANT=release
if [ "${1:-}" = "--local" ]; then VARIANT=local; fi
ICON="$PWD/../assets/logo/NotiVoice-${VARIANT}.icns"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotiVoice "$APP/Contents/MacOS/NotiVoice"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "提示：未找到 $ICON，App 将使用系统默认图标"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotiVoice</string>
<key>CFBundleIdentifier</key><string>cn.lemoai.notivoice</string>
<key>CFBundleName</key><string>NotiVoice</string>
<key>CFBundleDisplayName</key><string>Noti Voice</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/NotiVoice"
echo "构建完成：$APP"
open "$APP"
