#!/bin/bash
# Karu 发布流水线：打包 → 签名 → 公证 → 装订 → DMG。
# 红线：任何密钥（.p8 / .env* / .secrets.env）绝不进入产物；公证凭据只经
# 钥匙串 profile（tinyeditor-notary）引用，本脚本不含任何机密。
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-tinyeditor-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
APP_DIR="build/Karu.app"
ZIP_PATH="build/Karu.zip"
DMG_PATH="build/Karu.dmg"
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

echo "== [4/6] 重打更新包 + Sparkle 签名 + appcast =="
# Sparkle 更新通道用的 zip 必须是装订过票据的 app；私钥在 login keychain
# （generate_keys 生成，账户 ed25519），脚本内零机密。
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
SPARKLE_BIN="build/sparkle-tools/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
    SPARKLE_VER=$(python3 -c "import json; d=json.load(open('Package.resolved')); print([p['state']['version'] for p in d['pins'] if p['identity']=='sparkle'][0])")
    mkdir -p build/sparkle-tools
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
        | tar -xJ -C build/sparkle-tools
fi
BUILD_NUM="$(grep -A1 CFBundleVersion scripts/bundle-macos.sh | sed -n '2p' | sed 's/[^0-9]//g')"
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP_PATH")"   # sparkle:edSignature="…" length="…"
cat > build/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Karu</title>
    <item>
      <title>Karu ${VERSION}</title>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <link>https://github.com/enkin-japan/karu/releases/tag/v${VERSION}</link>
      <enclosure url="https://github.com/enkin-japan/karu/releases/download/v${VERSION}/Karu.zip"
                 type="application/octet-stream"
                 ${SIG_ATTRS}/>
    </item>
  </channel>
</rss>
APPCAST

echo "== [5/6] 制作并签名 DMG =="
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Karu ${VERSION}" \
    -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "Developer ID Application" "$DMG_PATH"

echo "== [6/6] Gatekeeper 终验 =="
spctl --assess --type execute -v "$APP_DIR"
codesign --verify --strict "$DMG_PATH"

# 红线终检：产物内不得有密钥类文件
if find "$APP_DIR" "$STAGING" \( -name '*.p8' -o -name '.env' -o -name '.env.*' -o -name '.secrets.env' \) -print 2>/dev/null | grep -q .; then
    echo "ERROR: secret files found in release artifacts — aborting" >&2
    exit 1
fi

echo ""
echo "RELEASE OK:"
du -sh "$APP_DIR" "$DMG_PATH" "$ZIP_PATH"
echo "发布时三个资产都要挂上 GitHub Release：Karu.dmg + Karu.zip + appcast.xml"
echo "（SUFeedURL 指向 releases/latest/download/appcast.xml，永远解析到最新版）"
