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
	<string>0.5.0</string>
	<key>CFBundleVersion</key>
	<string>7</string>
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
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

echo "OK: $APP_DIR"
du -sh "$APP_DIR"
