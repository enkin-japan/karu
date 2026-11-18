#!/bin/bash
# Karu 发布流水线：门禁 → 打包 → 签名 → 公证 → 装订 → DMG。
# 红线：任何密钥（.p8 / .env* / .secrets.env）绝不进入产物；公证凭据只经
# 钥匙串 profile（tinyeditor-notary）引用，本脚本不含任何机密。
#
# 门禁（在任何构建、签名、公证之前）：
#   1. 工作区必须干净；
#   2. build/preflight/<当前提交号>.json 必须是 scripts/preflight.sh 写下的通过记录
#      （完整测试、视觉冒烟、内存基准都通过）。升版本号的提交也要重新跑 preflight。
# Sparkle 的 sign_update 取自 SwiftPM 已按校验值验证过的二进制产物，并核对它与
# Package.resolved 锁定的版本一致（scripts/lib/verify-sparkle-tools.py）；
# 本脚本不再自行下载工具，也不再使用 build/sparkle-tools 里的旧缓存。
#
# `scripts/release-macos.sh --check`：只跑门禁和 Sparkle 工具核对然后退出，
#   不构建、不签名、不公证（核对 Sparkle 工具需要此前至少 swift build 过一次）。
# `KARU_RELEASE_SKIP_PREFLIGHT=1`：跳过门禁 1 和 2。只用于门禁本身出故障的情况，
#   使用时开头和结尾都会醒目提示；Sparkle 工具核对不可跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
elif [[ $# -gt 0 ]]; then
    echo "用法：scripts/release-macos.sh [--check]" >&2
    exit 2
fi

PREFLIGHT_SKIPPED=0
warn_preflight_skipped() {
    echo "################################################################" >&2
    echo "# 警告：KARU_RELEASE_SKIP_PREFLIGHT=1，发布前检查门禁已被跳过。 #" >&2
    echo "# 这次产物没有“当前提交通过完整测试、视觉冒烟、内存基准”的证据。#" >&2
    echo "################################################################" >&2
}

echo "== [0/6] 门禁：工作区与发布前检查记录 =="
if [[ "${KARU_RELEASE_SKIP_PREFLIGHT:-0}" == "1" ]]; then
    PREFLIGHT_SKIPPED=1
    warn_preflight_skipped
else
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "RELEASE REFUSED：工作区不干净。提交或清理后先运行 scripts/preflight.sh。" >&2
        git status --short >&2
        exit 1
    fi
    if ! python3 scripts/lib/check-preflight-record.py build/preflight "$(git rev-parse HEAD)"; then
        echo "RELEASE REFUSED：先在当前提交上运行 scripts/preflight.sh。" >&2
        exit 1
    fi
fi

# 核对并取得 Sparkle 的 sign_update；输出 path= / version= / revision= / artifact_checksum=。
resolve_sparkle_tool() {
    local info
    if ! info="$(python3 scripts/lib/verify-sparkle-tools.py Package.resolved .build)"; then
        echo "RELEASE REFUSED：Sparkle 签名工具与 Package.resolved 锁定的版本对不上。" >&2
        exit 1
    fi
    SPARKLE_SIGN_UPDATE="$(printf '%s\n' "$info" | sed -n 's/^path=//p')"
    echo "Sparkle 工具：$SPARKLE_SIGN_UPDATE"
    echo "  版本 $(printf '%s\n' "$info" | sed -n 's/^version=//p')，修订 $(printf '%s\n' "$info" | sed -n 's/^revision=//p')"
    echo "  产物校验值 $(printf '%s\n' "$info" | sed -n 's/^artifact_checksum=//p')"
    echo "  sign_update SHA-256 $(shasum -a 256 "$SPARKLE_SIGN_UPDATE" | awk '{print $1}')"
}

if [[ "$CHECK_ONLY" == "1" ]]; then
    resolve_sparkle_tool
    echo "CHECK OK：门禁通过。未构建、未签名、未公证。"
    exit 0
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-tinyeditor-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
APP_DIR="build/Karu.app"
ZIP_PATH="build/Karu.zip"
DMG_PATH="build/Karu.dmg"
VERSION="$(sed -n 's/.*CFBundleShortVersionString.*/v/p' scripts/bundle-macos.sh >/dev/null; \
           grep -A1 CFBundleShortVersionString scripts/bundle-macos.sh | tail -1 | sed 's/[^0-9.]//g')"

echo "== [1/6] 构建 + 签名（Developer ID, hardened runtime） =="
./scripts/bundle-macos.sh
# 构建之后、提交公证之前核对签名工具：对不上就不必白等一次公证。
resolve_sparkle_tool

echo "== [2/6] 提交公证（notarytool, profile: ${NOTARY_PROFILE}） =="
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" \
    --wait

echo "== [3/6] 装订公证票据到 .app =="
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "== [4/6] 重打更新包 + Sparkle 签名 + appcast =="
# Sparkle 更新通道用的 zip 必须是装订过票据的 app；私钥在 login keychain
# （generate_keys 生成，账户 ed25519），脚本内零机密。
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
BUILD_NUM="$(grep -A1 CFBundleVersion scripts/bundle-macos.sh | sed -n '2p' | sed 's/[^0-9]//g')"
SIG_ATTRS="$("$SPARKLE_SIGN_UPDATE" "$ZIP_PATH")"   # sparkle:edSignature="…" length="…"
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
if [[ "$PREFLIGHT_SKIPPED" == "1" ]]; then
    warn_preflight_skipped
fi
