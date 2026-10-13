#!/bin/zsh
# Requires the owner's Developer ID certificate and a notarytool Keychain profile.
set -eu
cd "${0:A:h:h}"
: "${SIGNING_IDENTITY:?请指定自己的 Developer ID Application 证书名称}"
: "${NOTARY_PROFILE:?请指定自己的 notarytool 钥匙串配置名称}"
if [[ "$SIGNING_IDENTITY" != 'Developer ID Application:'* ]]; then
  print -u2 '正式分享版需要 Developer ID Application 证书。'; exit 1
fi
zsh build.sh
release_dir='分享包/正式签名版'
mkdir -p "$release_dir"
ditto 'Codex用量.app' "$release_dir/Codex用量.app"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$release_dir/Codex用量.app"
codesign --verify --deep --strict "$release_dir/Codex用量.app"
ditto -c -k --keepParent "$release_dir/Codex用量.app" "$release_dir/提交公证.zip"
xcrun notarytool submit "$release_dir/提交公证.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$release_dir/Codex用量.app"
xcrun stapler validate "$release_dir/Codex用量.app"
spctl --assess --type execute --verbose=2 "$release_dir/Codex用量.app"
ditto -c -k --keepParent "$release_dir/Codex用量.app" '分享包/Codex用量-v2.0-已公证.zip'
shasum -a 256 '分享包/Codex用量-v2.0-已公证.zip' > '分享包/Codex用量-v2.0-已公证.zip.sha256'
