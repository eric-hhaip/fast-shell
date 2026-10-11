#!/usr/bin/env bash
# 把构建好的 Fast Shell 安装到 /Applications（macOS）。
#
# 为什么需要这个脚本（两次踩坑的教训）：
#  1. Flutter 增量构建后，`Frameworks/App.framework` 会在签名阶段之后被重新写入，
#     导致产物签名失效（codesign --verify 报 nested code is modified or invalid）。
#  2. 修复签名时**必须带 --entitlements**。漏掉它会把 app 的沙盒权限一起抹掉，
#     应用随后以「非沙盒」方式运行：家目录从沙盒容器切到真实 ~/Library，
#     于是读不到容器里的 vault.enc，表现就是「连接和分类全没了」（数据其实还在）。
# 所以：重签一律带 entitlements，且重签后必须校验签名与 app-sandbox 存在。
set -euo pipefail

APP="Fast Shell"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/macos/Build/Products/Release/$APP.app"
DST="/Applications/$APP.app"
ENT="$ROOT/macos/Runner/Release.entitlements"

if [ ! -d "$SRC" ]; then
  echo "✗ 未找到构建产物：$SRC"
  echo "  先执行：flutter build macos --release"
  exit 1
fi

echo "→ 退出正在运行的实例"
osascript -e "quit app \"$APP\"" 2>/dev/null || true
sleep 2
pkill -f "$DST/Contents/MacOS/$APP" 2>/dev/null || true
sleep 1

echo "→ 复制到 $DST"
rm -rf "$DST"
ditto "$SRC" "$DST"
xattr -cr "$DST"

# 只有签名失效时才重签；重签必须带 entitlements
if ! codesign --verify --deep --strict "$DST" 2>/dev/null; then
  echo "→ 产物签名失效（增量构建的常见现象），带 entitlements 重签"
  codesign --force --deep --sign - --entitlements "$ENT" "$DST"
fi

echo "→ 校验"
codesign --verify --deep --strict "$DST" && echo "  ✓ 签名有效"
if codesign -d --entitlements - "$DST" 2>&1 | grep -q "com.apple.security.app-sandbox"; then
  echo "  ✓ 沙盒权限在位（能读到容器里的连接数据）"
else
  echo "  ✗ 沙盒权限缺失！应用会以非沙盒运行、读不到已有数据。"
  echo "    修：codesign --force --deep --sign - --entitlements \"$ENT\" \"$DST\""
  exit 1
fi

echo "→ 启动"
open "$DST"
echo "✓ 安装完成：$DST"
