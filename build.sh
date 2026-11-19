#!/bin/bash
# 构建「画笔触控板」.app
# 用法：bash build.sh [输出目录]

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$HERE}"
APP_NAME="Finger Drawing"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 写入 Info.plist"
cp "$HERE/src/Info.plist" "$APP/Contents/Info.plist"

echo "==> 拷贝图标"
if [ -f "$HERE/src/AppIcon.icns" ]; then
    cp "$HERE/src/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "    AppIcon.icns 已放入 Resources"
else
    echo "    未找到 src/AppIcon.icns，跳过"
fi

echo "==> 编译 Swift 源码"
swiftc -swift-version 5 -O \
    -target arm64-apple-macos12.0 \
    -framework AppKit \
    -o "$APP/Contents/MacOS/FingerDrawing" \
    "$HERE/src/main.swift"

echo "==> 签名"
# 优先用本机 Apple Development 证书签名：辅助功能权限只在「满足代码要求」时才生效，
# ad-hoc 签名（-）会让系统里那条权限记录永远匹配不上，勾了也显示未授权。
# 用开发证书签名后，代码要求固定为 identifier + 该证书，重新编译也不会掉权限。
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "    使用证书：$IDENTITY"
    codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
else
    echo "    未找到 Apple Development 证书，退回 ad-hoc 签名（辅助功能权限可能无法生效）"
    codesign --force --deep --sign - "$APP"
fi

echo "==> 完成：$APP"
