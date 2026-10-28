#!/bin/zsh
# Builds FolderLock.app and installs it into /Applications (or ~/Applications).
set -e
cd "$(dirname "$0")"

APP=build/FolderLock.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/FolderLock"
cp Info.plist "$APP/Contents/Info.plist"

# Finder extension (right-click menu + "folder opened" detection)
EXT="$APP/Contents/PlugIns/FolderLockFinder.appex"
mkdir -p "$EXT/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -application-extension -module-name FolderLockFinder \
  FinderSync.swift -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/FolderLockFinder"
cp FinderSync-Info.plist "$EXT/Contents/Info.plist"

# App icon: render the locked-folder icon into an .icns
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
cat > build/icon.swift <<'EOF'
import Cocoa
import UniformTypeIdentifiers
let out = CommandLine.arguments[1]
for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = s * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: px, height: px)
        NSWorkspace.shared.icon(for: UTType.folder).draw(in: r)
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.33, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let z = sym.size
            sym.draw(in: NSRect(x: (CGFloat(px) - z.width) / 2, y: CGFloat(px) * 0.39 - z.height / 2, width: z.width, height: z.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
    }
}
EOF
swiftc -swift-version 5 build/icon.swift -o build/mkicon
build/mkicon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --entitlements FinderSync.entitlements "$EXT"
codesign --force --sign - "$APP"

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x FolderLock 2>/dev/null || true
rm -rf "$DEST/FolderLock.app"
cp -R "$APP" "$DEST/"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/FolderLock.app"
/System/Library/CoreServices/pbs -update
pluginkit -a "$DEST/FolderLock.app/Contents/PlugIns/FolderLockFinder.appex"
pluginkit -e use -i local.folderlock.app.findersync
killall Finder 2>/dev/null || true
echo "Installed to $DEST/FolderLock.app"
