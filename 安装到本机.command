#!/bin/zsh
set -eu
cd "${0:A:h}"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print '需要 Apple Command Line Tools。请先在终端运行 xcode-select --install，安装完成后重新运行此脚本。'
  exit 1
fi
CODEX_USAGE_ARCHS="$(uname -m)" zsh build.sh
install_dir="$HOME/Applications"
install_app="$install_dir/Codex用量.app"
mkdir -p "$install_dir"
# Stop only copies of this exact app at the destination being updated.
for running_pid in ${(f)"$(pgrep -x CodexUsage || true)"}; do
  [[ -n "$running_pid" ]] || continue
  running_path="$(ps -p "$running_pid" -o comm= || true)"
  if [[ "$running_path" == "$install_app/Contents/MacOS/CodexUsage" ]]; then kill -TERM "$running_pid" || true; fi
done
if [[ -d "$install_app" ]]; then
  ditto "$install_app" "$install_dir/Codex用量-更新前备份-$(date +%Y%m%d-%H%M%S).app"
fi
ditto 'Codex用量.app' "$install_app"
codesign --verify --deep --strict "$install_app"
open "$install_app"
print '安装完成。顶部菜单栏的两个百分比依次为 5 小时和每周剩余额度。'
