# 静态资源目录

App 的**所有静态资源**统一放在这里，各平台目录里的同类文件都是这里的生成物，不要直接改：

| 源文件 | 生成到 | 生成方式 |
| --- | --- | --- |
| `icon/app_icon.png`（1024×1024） | `macos/Runner/Assets.xcassets/AppIcon.appiconset/` | `./tool/generate_app_icons.sh` |
| 同上 | `windows/runner/resources/app_icon.ico` | 同上 |

换图标时：替换 `icon/app_icon.png`（建议 1024×1024 正方形，带透明边距的圆角方块），然后运行 `./tool/generate_app_icons.sh`，重新构建即可。
