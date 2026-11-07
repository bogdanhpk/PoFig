import AppKit

// The glass render is the material source; the SVG retains the original geometry.
// AppKit applies the native icon mask and exports the platform sizes.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
let material = assets.appendingPathComponent("PoFig-glass-source.png")
let hasMaterial = FileManager.default.fileExists(atPath: material.path)
let source = hasMaterial ? material : assets.appendingPathComponent("PoFig.svg")
guard let image = NSImage(contentsOf: source) else {
    fatalError("Could not load icon source")
}

func png(_ size: Int) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space, bitmapInfo: info) else {
        fatalError("Could not create icon bitmap")
    }
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    if hasMaterial {
        let scale = CGFloat(size) / 1024
        context.addPath(CGPath(roundedRect: CGRect(x: 96 * scale, y: 96 * scale, width: 832 * scale, height: 832 * scale),
                               cornerWidth: 184 * scale, cornerHeight: 184 * scale, transform: nil))
        context.clip()
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true,
               hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    guard let result = context.makeImage(), let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon PNG")
    }
    return data
}

let sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024]
var images: [Int: Data] = [:]
for size in sizes { images[size] = try png(size) }
try images[1024]!.write(to: assets.appendingPathComponent("PoFig.png"))

let iconset = root.appendingPathComponent("build/PoFig.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try images[size]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try images[size * 2]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["-c", "icns", "-o", assets.appendingPathComponent("PoFig.icns").path, iconset.path]
try conversion.run()
conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else { fatalError("iconutil failed") }

func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}
let windowsSizes = sizes.filter { $0 <= 256 }
var icon = Data()
append(UInt16(0), to: &icon)
append(UInt16(1), to: &icon)
append(UInt16(windowsSizes.count), to: &icon)
var offset = 6 + 16 * windowsSizes.count
for size in windowsSizes {
    let dimension = UInt8(size == 256 ? 0 : size)
    icon.append(contentsOf: [dimension, dimension, 0, 0])
    append(UInt16(1), to: &icon)
    append(UInt16(32), to: &icon)
    append(UInt32(images[size]!.count), to: &icon)
    append(UInt32(offset), to: &icon)
    offset += images[size]!.count
}
for size in windowsSizes { icon.append(images[size]!) }
try icon.write(to: assets.appendingPathComponent("PoFig.ico"))
print("Built PoFig.png, PoFig.icns and PoFig.ico from \(source.lastPathComponent)")
