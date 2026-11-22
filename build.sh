#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="FreeDisplay"
DIST_APP="dist/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"
CLI_LINK="/opt/homebrew/bin/freedisplay"

echo "==> [1/4] 编译 Release 原生二进制..."
swift build -c release

echo "==> [2/4] 生成高清应用图标与 .app 包..."
rm -rf "$DIST_APP"
mkdir -p "$DIST_APP/Contents/MacOS" "$DIST_APP/Contents/Resources/en.lproj" "$DIST_APP/Contents/Resources/zh-Hans.lproj"

cp ".build/release/${APP_NAME}" "$DIST_APP/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "$DIST_APP/Contents/Info.plist"
printf '"CFBundleDisplayName" = "FreeDisplay";\n' > "$DIST_APP/Contents/Resources/en.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "FreeDisplay";\n' > "$DIST_APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

ICONSET_DIR=".build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" <<'EOF'
import AppKit

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, filename) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = CGFloat(px) * 0.08
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(px) * 0.22
    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.06, green: 0.24, blue: 0.72, alpha: 1.0)
    ])!
    grad.draw(in: path, angle: -60)

    if let sym = NSImage(systemSymbolName: "display", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let tinted = sym.withSymbolConfiguration(cfg) {
            let symSize = tinted.size
            let drawRect = NSRect(
                x: (CGFloat(px) - symSize.width) / 2.0,
                y: (CGFloat(px) - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            tinted.draw(in: drawRect)
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
    }
}
EOF

iconutil -c icns "$ICONSET_DIR" -o "$DIST_APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$DIST_APP"

echo "==> [3/4] 安装到 /Applications 并配置命令行工具..."
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$INSTALL_APP"
cp -R "$DIST_APP" "$INSTALL_APP"

if [ -d "/opt/homebrew/bin" ]; then
    ln -sf "$INSTALL_APP/Contents/MacOS/${APP_NAME}" "$CLI_LINK"
    echo "    已链接 CLI: $CLI_LINK"
fi

echo "==> [4/4] 启动 FreeDisplay 菜单栏应用..."
open "$INSTALL_APP"
echo "完成！FreeDisplay 已安装至 $INSTALL_APP 并正在菜单栏运行。"
