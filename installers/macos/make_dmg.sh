#!/usr/bin/env bash
#
# 把构建好的 mova.app 打成 DMG。
#
# 用法：
#   installers/macos/make_dmg.sh            # 版本号自动从 pubspec.yaml 读
#   installers/macos/make_dmg.sh 1.2.3      # 手动指定
#
# 产出：dist/mova_mac_arm64.dmg
#
# 镜像里放两样东西：mova.app 和指向 /Applications 的软链接。
# 用户打开 DMG 后把 app 拖到 Applications 就装好了——这是 macOS
# 分发桌面应用最常见的形式。
#
# 为什么不用 PKG：PKG 适合要装后台服务（LaunchAgent）、内核扩展之类
# 系统级组件的场景，mova 目前没有，一个普通 app bundle 就够。
#
# 关于签名公证（重要）：
#   这份脚本**不做**代码签名与公证，所以别人拿到会看到 Gatekeeper 的
#   「无法打开，因为它来自身份不明的开发者」，需要右键 → 打开放行一次。
#   要彻底去掉这道提示，需要 Apple Developer 账号（¥688/年）：
#     1. codesign --force --deep --options runtime \
#          --sign "Developer ID Application: <名字> (TEAMID)" mova.app
#     2. ditto -c -k --keepParent mova.app mova.zip
#     3. xcrun notarytool submit mova.zip --apple-id ... --team-id ... \
#          --password ... --wait
#     4. xcrun stapler staple mova.app
#   配好之后在下面 hdiutil 之前插入这些步骤即可。自己用的话不必做。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

APP="build/macos/Build/Products/Release/mova.app"

if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP —— 先跑 flutter build macos --release" >&2
  exit 1
fi

# 版本号：优先用参数，其次从 pubspec.yaml 取（去掉 +build 后缀）。
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/^version: *//p' pubspec.yaml | head -1 | sed 's/+.*//')"
fi
echo "打包 mova $VERSION"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# cp -R 会保留 app 内部的符号链接与可执行权限——Flutter 打出来的
# app bundle 里两者都有，丢了 app 就起不来。这也是为什么 Artifact
# 那边必须先用 tar 打包（zip 会抹掉权限）。
cp -R "$APP" "$STAGING/"

# 软链接（不是别名文件）：hdiutil 能原样保留，且在所有 macOS 版本上
# 都能正常解析。create-dmg 用的也是这个做法。
ln -s /Applications "$STAGING/Applications"

mkdir -p dist
DMG="dist/mova_mac_arm64.dmg"
rm -f "$DMG"

# UDZO = 压缩过的只读镜像。挂不上任何写权限，正适合分发。
hdiutil create \
  -volname "mova $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

echo "已生成 $(pwd)/$DMG"
hdiutil imageinfo "$DMG" | grep -E "Format|Size Information" -A2 | head -6
