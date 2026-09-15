#!/bin/bash
# 重新生成 app 图标(改了 Sources/genicon.swift 之后跑这个)
# 用法: ./genicon.sh
#
# 为什么要单独一个脚本:
#   sips 不能直接把 png 转成 icns(会报 Error 13),
#   必须先生成 .iconset 目录(内含全部规定尺寸),再用 iconutil 打包。
#   这套多尺寸流程手敲容易漏项,固化成脚本。
set -e
cd "$(dirname "$0")"

BUILD="build"
PNG="$BUILD/AppIcon.png"
ICONSET="$BUILD/AppIcon.iconset"
OUT="Sources/AppIcon.icns"

mkdir -p "$BUILD"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> 编译图标生成器"
xcrun swiftc Sources/genicon.swift -o "$BUILD/genicon" \
  -framework AppKit -framework CoreGraphics -O

echo "==> 绘制 1024x1024 PNG"
"$BUILD/genicon" "$PNG"

echo "==> 生成 iconset 各尺寸"
sips -z 16 16     "$PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$PNG" "$ICONSET/icon_512x512@2x.png"

echo "==> 打包 icns"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "==> 完成:$OUT ($(du -h "$OUT" | cut -f1))"
echo "    接着跑 ./build.sh 装到 /Applications,再 killall Dock 刷新缓存。"
