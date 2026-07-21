#!/bin/bash
# Karu 打包脚本：SPM release 产物 → Karu.app
# 红线：.p8 / .env* / .secrets.env 绝不允许进入 bundle（脚本末尾强制检查）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP_DIR="build/Karu.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/KaruApp "$APP_DIR/Contents/MacOS/Karu"
cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# 终端辅助工具（T8.5）：用户可从 bundle 内 symlink 到 PATH 使用
install -m 0755 scripts/karu "$APP_DIR/Contents/Resources/karu"

# Sparkle 一键更新框架（M11）：SPM binary artifact → Contents/Frameworks。
# 可执行文件带 @executable_path/../Frameworks rpath（见 Package.swift）。
SPARKLE_FW=$(ls -d .build/artifacts/*/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework 2>/dev/null | head -1)
if [[ -z "$SPARKLE_FW" ]]; then
    echo "ERROR: Sparkle.framework artifact not found (run swift build first)" >&2
    exit 1
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Karu</string>
	<key>CFBundleDisplayName</key>
	<string>Karu</string>
	<key>CFBundleExecutable</key>
	<string>Karu</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Text Document</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.text</string>
				<string>public.plain-text</string>
				<string>public.source-code</string>
				<string>public.json</string>
				<string>public.xml</string>
				<string>net.daringfireball.markdown</string>
				<string>public.data</string>
			</array>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>txt</string><string>md</string><string>markdown</string>
				<string>json</string><string>jsonl</string><string>ndjson</string>
				<string>py</string><string>pyw</string><string>js</string>
				<string>mjs</string><string>cjs</string><string>ts</string>
				<string>html</string><string>htm</string><string>css</string>
				<string>c</string><string>h</string><string>cpp</string>
				<string>cc</string><string>cxx</string><string>hpp</string>
				<string>hh</string><string>cs</string><string>java</string>
				<string>sh</string><string>bash</string><string>zsh</string>
				<string>sql</string><string>xml</string><string>plist</string>
				<string>svg</string><string>log</string><string>cfg</string>
				<string>ini</string><string>yaml</string><string>yml</string>
				<string>toml</string>
			</array>
		</dict>
	</array>
	<key>CFBundleIdentifier</key>
	<string>dev.enkin.TinyEditor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.7.0</string>
	<key>CFBundleVersion</key>
	<string>9</string>
	<key>SUFeedURL</key>
	<string>https://github.com/enkin-japan/karu/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>rO8YyJT++AQ8w9YIhWVaY2YTlLvdSZIXCZrPeR1A2jI=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# 红线检查：任何密钥类文件出现在 bundle 内立即失败
if find "$APP_DIR" \( -name '*.p8' -o -name '.env' -o -name '.env.*' -o -name '.secrets.env' \) -print | grep -q .; then
    echo "ERROR: secret files found inside bundle — aborting" >&2
    exit 1
fi

# 签名：默认 Developer ID + hardened runtime（公证要求）；
# SIGN_IDENTITY=- 可切回 ad-hoc 本地开发签名。
# Sparkle 组件必须由内向外显式签名（Apple 不建议 --deep）：
# XPC 服务 → Autoupdate → Updater.app → 框架本体 → app。
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
sign_component() {
    local path=$1
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - --preserve-metadata=entitlements "$path"
    else
        codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$path"
    fi
}
sign_component "$FW/Versions/B/XPCServices/Downloader.xpc"
sign_component "$FW/Versions/B/XPCServices/Installer.xpc"
sign_component "$FW/Versions/B/Autoupdate"
sign_component "$FW/Versions/B/Updater.app"
sign_component "$FW"
sign_component "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "OK: $APP_DIR"
du -sh "$APP_DIR"
