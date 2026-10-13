#!/bin/zsh
set -eu
cd "${0:A:h:h}"
zsh build.sh
mkdir -p '分享包/Codex用量-v2.0'
ditto 'Codex用量.app' '分享包/Codex用量-v2.0/Codex用量.app'
cp 分享说明.txt '分享包/Codex用量-v2.0/安装说明.txt'
codesign --verify --deep --strict '分享包/Codex用量-v2.0/Codex用量.app'
ditto -c -k --keepParent '分享包/Codex用量-v2.0' '分享包/Codex用量-v2.0-macOS-通用版-未公证.zip'
python3 - <<'PY'
import zipfile
from pathlib import Path
destination = Path('分享包/Codex用量-v2.0-源码安装包.zip')
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for folder in ['Sources', 'Tests', 'Scripts', 'AppTemplate']:
        for path in Path(folder).rglob('*'):
            if path.is_file(): archive.write(path, Path('Codex用量-v2.0-源码') / path)
    for name in ['build.sh', '安装到本机.command', 'README.md', 'ACKNOWLEDGEMENTS.md', 'LICENSE', 'PRIVACY.md', 'SECURITY.md', 'CONTRIBUTING.md', 'TESTING.md', 'CHANGELOG.md', '分享说明.txt']:
        archive.write(name, Path('Codex用量-v2.0-源码') / name)
for path in [destination, Path('分享包/Codex用量-v2.0-macOS-通用版-未公证.zip')]:
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
    print('打包校验通过：', path)
PY
shasum -a 256 分享包/Codex用量-v2.0-*.zip > 分享包/Codex用量-v2.0-SHA256.txt
