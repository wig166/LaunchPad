#!/bin/bash
# LaunchPad 构建脚本(无需 Xcode,只用 Command Line Tools 的 swiftc)
# 用法: ./build.sh
set -e
cd "$(dirname "$0")"

# ★★ 唯一的 app 副本就放在 /Applications。
#    千万不要在工作区里再留一份 —— 两处同时存在会让 LaunchServices
#    注册出两条记录,TCC 认错 app,表现为「明明授权过还反复弹窗」。
#    (2026-09-01 踩过一次:工作区根目录留了个空壳,折腾了两小时。)
APP="/Applications/LaunchPad.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
# 注意两点:
#  1. 不要加 -target arm64-apple-macosx13.0,会触发一堆
#     "only available in macOS 14.0" 的误报。用默认宿主 SDK 即可。
#  2. 链 Carbon 而不是 ApplicationServices —— 全局快捷键已经改用
#     registerEventHotKey,不再需要辅助功能权限(见 Sources/main.swift 注释)。
xcrun swiftc \
  Sources/AppScanner.swift \
  Sources/LaunchpadModel.swift \
  Sources/IconCache.swift \
  Sources/AppGrid.swift \
  Sources/WallpaperBackground.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/LaunchPad" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -O

echo "==> 拷贝 Info.plist"
# ★ 必须拷:CFBundleLocalizations 决定了 app 显示名能不能本地化成中文
cp Sources/Info.plist "$APP/Contents/Info.plist"

echo "==> 拷贝图标"
if [ -f Sources/AppIcon.icns ]; then
  cp Sources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 重新签名(ad-hoc,固定 identifier)"
# ★ 签名前必须清掉旧的 _CodeSignature。
#   原因(2026-09-16 踩坑):codesign 会先把包内文件清单写进 CodeResources,
#   如果上一轮的密封清单还在,它会把上次签名留下的临时文件引用
#   (MacOS/LaunchPad.cstemp)当成"包内资源"一并封进新签名。
#   结果:签名在 codesign -vv 下报 "a sealed resource is missing or invalid",
#   别人下载后 Gatekeeper 直接判「文件已损坏」,右键打开都救不回来。
#   —— 那天的 v1.12 首发包就是这么坏的。
# ★ 另外不要用 --deep:包内没有嵌套的 framework/插件,--deep 反而容易
#   在签名过程中生成 .cstemp 临时文件并被封进资源清单。
rm -rf "$APP/Contents/_CodeSignature"
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
codesign --force --sign - \
  --identifier com.xingxing.launchpad \
  --entitlements Sources/LaunchPad.entitlements \
  "$APP"

# ★ 签名**之后**再清一次。
#   2026-09-16 又踩到:codesign 自己会在 Contents/MacOS 里留一个
#   LaunchPad.cstemp(它写临时文件再改名,改名留下的残骸不会自己消失)。
#   签名时它还不存在,所以签名前的清理管不到它,自检当时也是"valid";
#   等下次再校验就变成 "code has no resources but signature indicates
#   they must be present" —— 别人下载后又是"文件已损坏"。
#   所以前后各清一次,别省这一步。
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true

echo "==> 签名自检(密封清单里不能出现 .cstemp 残留)"
if ! codesign -vv --strict "$APP" 2>&1 | tail -2; then
  echo "❌ 签名无效,中止"
  exit 1
fi

echo "==> 重新注册到 LaunchServices"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true

echo "==> 安全检查:是否有同 bundle ID 的重复副本"
# 为什么必须查这一条:
#   同 bundle ID 的第二份 app,会被 LaunchServices 判定成「同一个 app」。
#   后果是:你双击 /Applications 里的新版,系统却把那份旧副本唤到前台 ——
#   表现为「明明重新构建了,行为还是旧的」;而旧副本如果还带着辅助功能调用,
#   就会每次点击都弹「想使用辅助功能来控制这台电脑」。
#   (2026-09-15 踩过:9/1 的调试副本留在 /private/tmp,还被拖进了 Dock。)
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
DUPES=$(/usr/bin/find /private/tmp "$HOME/Desktop" "$HOME/Downloads" "$HOME/Applications" "$(pwd)" \
  -maxdepth 5 -name "*.app" -type d -prune -print 2>/dev/null | while read -r cand; do
    [ "$cand" = "$APP" ] && continue
    cbid=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$cand/Contents/Info.plist" 2>/dev/null || true)
    [ "$cbid" = "$BID" ] && echo "$cand"
  done || true)

if [ -n "$DUPES" ]; then
  echo "⚠️  发现同 bundle ID 的重复副本,已移入废纸篓(会被系统当成同一个 app,劫持启动):"
  echo "$DUPES" | while read -r d; do
    [ -z "$d" ] && continue
    mv "$d" "$HOME/.Trash/$(basename "$d")-dup-$(date +%s)" 2>/dev/null && echo "    → $d"
  done
  echo "    如果 Dock 上有图标指向它,请把旧图标拖出去、重新拖入 $APP"
else
  echo "    ✓ 无重复副本"
fi

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "==> 完成:v$VER (build $BUILD)  →  $APP"
echo "    如果 Dock 图标没变,执行: killall Dock"
