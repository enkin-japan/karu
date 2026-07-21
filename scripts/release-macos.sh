#!/bin/bash
# TinyEditor 发布流水线：打包 → 签名 → 公证 → 装订 → DMG。
# 红线：任何密钥（.p8 / .env* / .secrets.env）绝不进入产物；公证凭据只经
# 钥匙串 profile（tinyeditor-notary）引用，本脚本不含任何机密。
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-tinyeditor-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
APP_DIR="build/TinyEditor.app"
ZIP_PATH="build/TinyEditor.zip"
DMG_PATH="build/TinyEditor.dmg"
VERSION="$(sed -n 's/.*CFBundleShortVersionString.*/v/p' scripts/bundle-macos.sh >/dev/null; \
           grep -A1 CFBundleShortVersionString scripts/bundle-macos.sh | tail -1 | sed 's/[^0-9.]//g')"

echo "== [1/5] 构建 + 签名（Developer ID, hardened runtime） =="
./scripts/bundle-macos.sh

echo "== [2/5] 提交公证（notarytool, profile: ${NOTARY_PROFILE}） =="
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" \
    --wait

echo "== [3/5] 装订公证票据到 .app =="
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "== [4/5] 制作并签名 DMG =="
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "TinyEditor ${VERSION}" \
    -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "Developer ID Application" "$DMG_PATH"

echo "== [5/5] Gatekeeper 终验 =="
spctl --assess --type execute -v "$APP_DIR"
codesign --verify --strict "$DMG_PATH"

# 红线终检：产物内不得有密钥类文件
if find "$APP_DIR" "$STAGING" \( -name '*.p8' -o -name '.env' -o -name '.env.*' -o -name '.secrets.env' \) -print 2>/dev/null | grep -q .; then
    echo "ERROR: secret files found in release artifacts — aborting" >&2
    exit 1
fi

echo ""
echo "RELEASE OK:"
du -sh "$APP_DIR" "$DMG_PATH"
