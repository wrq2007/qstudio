#!/bin/zsh
# 构建 Q Studio.app —— 自包含运行时，不依赖系统 Vulkan SDK
set -e

# 所有路径可用环境变量覆盖。构建前请设置 LLAMA / VKSDK 指向你本机的依赖：
#   LLAMA  = llama.cpp 的 Vulkan 构建产物目录（含 llama-server 与 dylib）
#   VKSDK  = VulkanSDK 的 macOS/lib 目录（含 libMoltenVK.dylib）
ROOT=${ROOT:-"$(cd "$(dirname "$0")" && pwd)"}
SRC=$ROOT/Sources
BUILD=${BUILD:-"$ROOT/build"}
APP="$BUILD/Q Studio.app"
LLAMA=${LLAMA:-"$HOME/tools/llama.cpp-master/build-vk/bin"}
VKSDK=${VKSDK:-"$HOME/tools/VulkanSDK/macOS/lib"}

# 依赖检查：给出明确报错，而不是让 cp 静默失败
if [ ! -f "$LLAMA/llama-server" ]; then
  echo "找不到 llama-server：$LLAMA/llama-server" >&2
  echo "请先编译 llama.cpp 的 Vulkan 版本，或用 LLAMA=/path/to/bin 指定。" >&2
  exit 1
fi
if [ ! -f "$VKSDK/libMoltenVK.dylib" ]; then
  echo "找不到 MoltenVK：$VKSDK/libMoltenVK.dylib" >&2
  echo "请用 VKSDK=/path/to/VulkanSDK/macOS/lib 指定。" >&2
  exit 1
fi

SDK=$(xcrun --show-sdk-path)
EXE=$APP/Contents/MacOS/LocalModel
FW=$APP/Contents/Frameworks

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FW"

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 \
  -target x86_64-apple-macos14.0 \
  -sdk "$SDK" \
  -framework AppKit -framework SwiftUI -framework Metal -framework IOKit -framework WebKit \
  "$SRC"/*.swift \
  -o "$EXE"

echo "==> 拷贝推理运行时"
cp "$LLAMA/llama-server" "$FW/"
chmod +x "$FW/llama-server"
for f in libggml-base libggml-blas libggml-cpu libggml-vulkan libggml libllama libllama-common libmtmd; do
  cp "$LLAMA/$f.1.dylib" "$FW/" 2>/dev/null || true
done
cp "$LLAMA/libllama-server-impl.dylib" "$FW/" 2>/dev/null || true
cp "$VKSDK/libvulkan.1.4.363.dylib" "$FW/libvulkan.1.dylib"
cp "$VKSDK/libMoltenVK.dylib" "$FW/libMoltenVK.dylib"

echo "==> 裁剪为 x86_64（本项目只面向 Intel Mac）"
for f in "$FW"/*.dylib "$FW/llama-server" "$EXE"; do
  archs=$(lipo -archs "$f" 2>/dev/null || echo "")
  if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then
    lipo -thin x86_64 "$f" -output "$f.thin" 2>/dev/null && mv "$f.thin" "$f" && chmod +x "$f"
    echo "  thin: $(basename "$f") ($archs → x86_64)"
  fi
done

echo "==> 修正 rpath 指向 app 内部"
# 把绝对路径 rpath 换成 app 内部相对路径，保证拷到任何机器都能找到库
fix_rpath() {
  local bin="$1"
  local rp
  otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{getline; getline; print $2}' > /tmp/.rpaths.$$
  while IFS= read -r rp; do
    [[ -z "$rp" ]] && continue
    install_name_tool -delete_rpath "$rp" "$bin" 2>&1 | grep -v "will invalidate" || true
  done < /tmp/.rpaths.$$
  rm -f /tmp/.rpaths.$$
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>&1 | grep -v "will invalidate" || true
  install_name_tool -add_rpath "@loader_path" "$bin" 2>&1 | grep -v "will invalidate" || true
}

fix_rpath "$EXE"
for lib in "$FW"/*.dylib; do
  fix_rpath "$lib"
done
fix_rpath "$FW/llama-server"

show_rpath() {
  otool -l "$1" 2>/dev/null | grep -A2 LC_RPATH | grep ' path ' | sed 's/.*path //' | tr '\n' ' '
}
echo "  LocalModel    → $(show_rpath "$EXE")"
echo "  llama-server  → $(show_rpath "$FW/llama-server")"

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Q Studio</string>
    <key>CFBundleDisplayName</key>     <string>Q Studio</string>
    <key>CFBundleExecutable</key>      <string>LocalModel</string>
    <key>CFBundleIdentifier</key>      <string>com.lens.localmodel</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.1.2</string>
    <key>CFBundleVersion</key>         <string>4</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

if [ -f "$ROOT/AppIcon.icns" ]; then
  cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 本地化资源"
# 先生成 .strings，再把 en/zh-Hans 两个 lproj 拷进 bundle
python3 "$ROOT/Tools/gen_localization.py" >/dev/null
for lproj in en.lproj zh-Hans.lproj; do
  if [ -d "$ROOT/Resources/$lproj" ]; then
    cp -R "$ROOT/Resources/$lproj" "$APP/Contents/Resources/$lproj"
  fi
done
# KaTeX（离线公式渲染，禁止走 CDN）
if [ -d "$ROOT/Resources/katex" ]; then
  rm -rf "$APP/Contents/Resources/katex"
  cp -R "$ROOT/Resources/katex" "$APP/Contents/Resources/katex"
fi
# 菜单栏模板图（19/38 两档，系统按深浅色自动反色）
for icon in MenuIcon.png MenuIcon@2x.png; do
  [ -f "$ROOT/Resources/$icon" ] && cp "$ROOT/Resources/$icon" "$APP/Contents/Resources/$icon"
done

echo "==> 签名"
codesign --force --deep --sign - "$APP" 2>&1 | tail -2 || true

echo "==> 依赖自检"
MISSING=0
for bin in "$EXE" "$FW"/*.dylib; do
  otool -L "$bin" 2>/dev/null | awk '{print $1}' | grep "^@rpath/" | sed 's|@rpath/||' | while read -r dep; do
    [ -f "$FW/$dep" ] || echo "  ✗ 缺少 $dep (由 $(basename $bin) 引用)"
  done
done
echo "  检查完毕"

echo
echo "完成: $APP"
du -sh "$APP"
