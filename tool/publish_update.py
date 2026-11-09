"""After both platform builds succeed, describe the exact Release assets."""
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

root = Path(__file__).resolve().parents[1]
asset_dir, repository, tag = sys.argv[1:]
version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.M)[1]
name, code = version.split('+')
if tag != f'v{name}':
    raise SystemExit(f'Tag {tag} must match pubspec version v{name}')
base = f'https://github.com/{repository}/releases/download/{quote(tag, safe="")}'
files = {'windows-x64': 'mova_win_x64_setup.exe', 'macos-arm64': 'mova_mac_arm64.zip'}
assets = {}
for platform, filename in files.items():
    size = (Path(asset_dir) / filename).stat().st_size
    if size <= 0:
        raise SystemExit(f'Empty asset: {filename}')
    assets[platform] = {'url': f'{base}/{filename}', 'size': size}
manifest = {'versionName': name, 'versionCode': int(code),
            'url': f'https://github.com/{repository}/releases/tag/{quote(tag, safe="")}',
            'notes': '新版本已发布，详细说明见下载页。', 'assets': assets}
(Path(asset_dir) / 'version.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
