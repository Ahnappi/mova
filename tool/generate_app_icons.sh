#!/usr/bin/env bash
# 从统一源图生成各平台应用图标。
#
# 约定：App 的所有静态资源都放在仓库根的 assets/ 下（图标在 assets/icon/），
# 各平台目录里的图标文件都是这里的生成物，不要直接改：
#   - macOS  -> macos/Runner/Assets.xcassets/AppIcon.appiconset/
#   - Windows-> windows/runner/resources/app_icon.ico
#
# 用法：./tool/generate_app_icons.sh
# 依赖：sips（macOS 自带）、带 Pillow 的 python（用于生成 .ico）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/assets/icon/app_icon.png"
MACSET="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WINICO="$ROOT/windows/runner/resources/app_icon.ico"

if [ ! -f "$SRC" ]; then
  echo "缺少源图标：$SRC" >&2
  exit 1
fi

# ---------- macOS ----------
# 尺寸与 AppIcon.appiconset/Contents.json 的条目一一对应。
for size in 16 32 64 128 256 512 1024; do
  sips -Z "$size" "$SRC" --out "$MACSET/app_icon_${size}.png" >/dev/null
done
echo "macOS 图标已生成 -> $MACSET"

# ---------- Windows ----------
# .ico 需要内嵌多个尺寸（任务栏 16/32、桌面 48、资源管理器 256 等），
# sips 不支持 ico 输出，交给 Pillow 合成。
PY_BIN="${PYTHON_BIN:-}"
if [ -z "$PY_BIN" ]; then
  for candidate in /Users/ahnappi/.workbuddy/binaries/python/envs/default/bin/python python3; do
    if "$candidate" -c "import PIL" >/dev/null 2>&1; then
      PY_BIN="$candidate"
      break
    fi
  done
fi
if [ -z "$PY_BIN" ]; then
  echo "未找到带 Pillow 的 python，无法生成 .ico（pip install pillow 后重试）" >&2
  exit 1
fi

"$PY_BIN" - "$SRC" "$WINICO" <<'PY'
import sys

from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")
if img.width != img.height:
    raise SystemExit(f"源图标不是正方形：{img.size}")
# Windows 官方要求的整尺寸集合；Pillow 会自行缩放并打包进单个 .ico。
sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
img.save(dst, format="ICO", sizes=sizes)
print(f"已写入 {dst}（内嵌 {len(sizes)} 个尺寸）")
PY
echo "Windows 图标已生成 -> $WINICO"
