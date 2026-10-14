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
#  3. **构建没跑完就安装**：后台 `flutter build` 还在跑时执行本脚本，会把上一轮的
#     旧产物装进 /Applications，出现「代码是新的、签名是旧的」这种半成品状态。
#     下面加了产物新鲜度校验，拦住这种情况。
#
# 现在的做法：**不再使用 App Sandbox**（见 macos/Runner/Release.entitlements 注释），
# 连接数据固定存 ~/Library/Application Support/FastShell/，脱离容器生命周期。
# 所以：重签一律带 entitlements，并校验签名有效 + 无沙盒残留 + 数据目录可写。
set -euo pipefail

APP="Fast Shell"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/macos/Build/Products/Release/$APP.app"
DST="/Applications/$APP.app"
ENT="$ROOT/macos/Runner/Release.entitlements"
# 每次重新签名都会重写这个文件，用它代表「产物签名的时刻」
STAMP="$SRC/Contents/_CodeSignature/CodeResources"

if [ ! -d "$SRC" ]; then
  echo "✗ 未找到构建产物：$SRC"
  echo "  先执行：flutter build macos --release"
  exit 1
fi

# —— 新鲜度校验：entitlements 改过却没重新构建时，产物签名会比它旧 ——
if [ -f "$STAMP" ] && [ "$ENT" -nt "$STAMP" ]; then
  echo "✗ 构建产物比 $ENT 还旧，说明改完 entitlements 没有重新构建。"
  echo "  entitlements 文件：$(date -r "$ENT" '+%Y-%m-%d %H:%M:%S')"
  echo "  产物签名时间：    $(date -r "$STAMP" '+%Y-%m-%d %H:%M:%S')"
  echo "  请先执行：flutter build macos --release（等它真正结束再安装）"
  exit 1
fi

# —— 产物自检：本项目不用沙盒，产物里不该出现 app-sandbox ——
if codesign -d --entitlements :- "$SRC" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "✗ 构建产物带 app-sandbox，与「不使用 App Sandbox」的设定不符。"
  echo "  多半是装到了旧构建。请重新执行：flutter build macos --release"
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
if codesign -d --entitlements :- "$DST" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "  ✗ 安装后仍带 app-sandbox（与 Release.entitlements 不符），数据会写进沙盒容器。"
  echo "    修：codesign --force --deep --sign - --entitlements \"$ENT\" \"$DST\""
  exit 1
fi
echo "  ✓ 无沙盒残留（数据存容器外，不会随容器重置丢失）"
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
