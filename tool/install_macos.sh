#!/usr/bin/env bash
# 把构建好的 Fast Shell 安装到 /Applications（macOS）。
#
# 为什么需要这个脚本（踩过的坑）：
#  1. Flutter 增量构建后，`Frameworks/App.framework` 会在签名阶段之后被重新写入，
#     导致产物签名失效（codesign --verify 报 nested code is modified or invalid）。
#  2. 修复签名时**必须带 --entitlements**。漏掉它会把 app 的权限一并抹掉。
#     历史上本项目启用过 App Sandbox，漏 entitlements 会让应用以「非沙盒」方式运行，
#     家目录从沙盒容器切到真实 ~/Library，读不到容器里的 vault.enc——
#     用户看到的就是「连接和分类全没了」（数据其实还在）。
# 现在的做法：**不再使用 App Sandbox**（见 macos/Runner/Release.entitlements 注释），
# 连接数据固定存 ~/Library/Application Support/FastShell/，脱离容器生命周期。
# 所以：重签一律带 entitlements，并校验签名有效 + 数据目录可写。
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
if codesign -d --entitlements - "$DST" 2>&1 | grep -q "com.apple.security.network.client"; then
  echo "  ✓ 出站网络权限在位（SSH / SFTP 必须）"
else
  echo "  ✗ 出站网络权限缺失！应用将无法建立 SSH 连接。"
  echo "    修：codesign --force --deep --sign - --entitlements \"$ENT\" \"$DST\""
  exit 1
fi

# 数据目录可写性检查：连接配置固定存 ~/Library/Application Support/FastShell/
DATA_DIR="$HOME/Library/Application Support/FastShell"
if mkdir -p "$DATA_DIR" 2>/dev/null && [ -w "$DATA_DIR" ]; then
  echo "  ✓ 数据目录可写：$DATA_DIR"
else
  echo "  ✗ 数据目录不可写：$DATA_DIR"
  exit 1
fi

echo "→ 启动"
open "$DST"
echo "✓ 安装完成：$DST"
