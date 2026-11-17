#!/bin/bash
# 打包发布用 DMG：带背景图、箭头和图标位置。
#
# 以前是手工 hdiutil 三段式（ditto / ln -s / hdiutil create），
# 生成的 DMG 打开就是两个裸图标，没有任何提示。
# 现在用 dmgbuild 直接写 .DS_Store 排版——不需要 Finder 自动化权限
# （这台机器 osascript 调 Finder 会报 -10004）。
#
# 用法：Tools/make_dmg.sh [版本号]
#   依赖：pip3 install --user dmgbuild

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "build/Q Studio.app/Contents/Info.plist")}"
APP="build/Q Studio.app"
OUT="QStudio-$VERSION.dmg"
DMGBUILD="${HOME}/.local/bin/dmgbuild"

[ -d "$APP" ] || { echo "找不到 $APP，先跑 ./build.sh"; exit 1; }
[ -x "$DMGBUILD" ] || { echo "缺少 dmgbuild：pip3 install --user dmgbuild"; exit 1; }

# 背景图缺了就重新生成
if [ ! -f Resources/dmg-background.png ]; then
  echo "==> 生成安装背景图"
  swift Tools/DmgBackground.swift Resources
fi

echo "==> 打包 ${OUT}（卷名 Q Studio ${VERSION}）"
rm -f "$OUT"
"$DMGBUILD" \
  -s Tools/dmg_settings.py \
  -D "app=$PWD/$APP" \
  -D "resources=$PWD/Resources" \
  -D "volname=Q Studio $VERSION" \
  "Q Studio $VERSION" "$OUT"

ls -lh "$OUT"
