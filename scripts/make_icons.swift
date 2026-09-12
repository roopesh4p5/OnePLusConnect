// Generates the app icons for both apps from logo.png.
// Usage: swift scripts/make_icons.swift            (run from the repository root)
// Output: mac/Resources/AppIcon.icns, android/app/src/main/res/mipmap-*/…, drawable-nodpi/logo.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = FileManager.default.currentDirectoryPath
let logoPath = "\(root)/logo.png"

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("Cannot read \(path)")
    }
    return img
}

/// Draws `logo` scaled to `fraction` of a square canvas, centered, on a transparent (or solid) background.
func render(size: Int, logo: CGImage, fraction: CGFloat, background: CGColor? = nil) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    if let bg = background { ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    let lw = CGFloat(logo.width), lh = CGFloat(logo.height)
    let target = CGFloat(size) * fraction
    let scale = min(target / lw, target / lh)
    let w = lw * scale, h = lh * scale
    ctx.draw(logo, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("dest \(path)") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(path)") }
    print("wrote \(path)")
}

/// Average colour of the logo body (sampled in the plain top-left interior) for the adaptive-icon background.
func bodyColor(_ logo: CGImage) -> (r: Int, g: Int, b: Int) {
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(logo, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var r = 0, g = 0, b = 0, n = 0
    for y in 48...54 { for x in 8...14 { let i = (y * 64 + x) * 4; r += Int(p[i]); g += Int(p[i+1]); b += Int(p[i+2]); n += 1 } }
    return (r / n, g / n, b / n)
}

let logo = loadImage(logoPath)
print("logo \(logo.width)x\(logo.height)")

// ---------------- macOS .icns (iconset → iconutil)
let iconset = "\(root)/mac/build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    // macOS icons sit inside a ~10% margin; the logo is already a rounded square.
    writePNG(render(size: px, logo: logo, fraction: 0.82), "\(iconset)/\(name).png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(root)/mac/Resources/AppIcon.icns"]
try? FileManager.default.createDirectory(atPath: "\(root)/mac/Resources", withIntermediateDirectories: true)
try iconutil.run(); iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote mac/Resources/AppIcon.icns" : "iconutil failed (\(iconutil.terminationStatus))")

// ---------------- Android
let res = "\(root)/android/app/src/main/res"
let densities: [(String, CGFloat)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]
let (br, bg, bb) = bodyColor(logo)
let bgColor = CGColor(srgbRed: CGFloat(br) / 255, green: CGFloat(bg) / 255, blue: CGFloat(bb) / 255, alpha: 1)
for (name, d) in densities {
    // Legacy launcher icon (48dp), used by a few launchers/settings screens.
    writePNG(render(size: Int(48 * d), logo: logo, fraction: 1.0), "\(res)/mipmap-\(name)/ic_launcher.png")
    writePNG(render(size: Int(48 * d), logo: logo, fraction: 1.0), "\(res)/mipmap-\(name)/ic_launcher_round.png")
    // Adaptive foreground (108dp canvas, 66dp safe zone). Logo body colour continues into the background layer,
    // so whatever the launcher mask trims still looks like one piece.
    writePNG(render(size: Int(108 * d), logo: logo, fraction: 0.80, background: bgColor), "\(res)/mipmap-\(name)/ic_launcher_foreground.png")
}
writePNG(render(size: 512, logo: logo, fraction: 1.0), "\(res)/drawable-nodpi/logo.png")
print(String(format: "adaptive background colour: #%02X%02X%02X", br, bg, bb))
