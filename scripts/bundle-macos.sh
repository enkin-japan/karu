#!/bin/bash
# TinyEditor 打包脚本：SPM release 产物 → TinyEditor.app
# 红线：.p8 / .env* / .secrets.env 绝不允许进入 bundle（脚本末尾强制检查）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP_DIR="build/TinyEditor.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/TinyEditorApp "$APP_DIR/Contents/MacOS/TinyEditor"
cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>TinyEditor</string>
	<key>CFBundleDisplayName</key>
	<string>TinyEditor</string>
	<key>CFBundleExecutable</key>
	<string>TinyEditor</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>dev.enkin.TinyEditor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
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
