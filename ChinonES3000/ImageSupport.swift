//  ImageSupport.swift — turning decoded pictures into CGImages and saving them.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG", tiff = "TIFF"
    var id: String { rawValue }
    var ext: String {
        switch self { case .png: return "png"; case .jpeg: return "jpg"; case .tiff: return "tif" }
    }
    var utType: UTType {
        switch self { case .png: return .png; case .jpeg: return .jpeg; case .tiff: return .tiff }
    }
    static let allExtensions = ["png", "jpg", "jpeg", "tif", "tiff"]
}

extension RGBImage {
    var cgImage: CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = pixels[i * 3]
            rgba[i * 4 + 1] = pixels[i * 3 + 1]
            rgba[i * 4 + 2] = pixels[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }

    /// Rotates by a multiple of 90° counter-clockwise (like PIL's rotate(angle, expand=True)).
    func rotated(by degrees: Int) -> CGImage {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0 else { return self }
        let swap = d == 90 || d == 270
        let w = swap ? height : width, h = swap ? width : height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return self }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(d) * .pi / 180)        // CG's y axis points up: positive = counter-clockwise
        ctx.draw(self, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                                  width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage() ?? self
    }

    func save(to url: URL, format: ImageFormat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil)
        else { throw CameraError("Cannot create \(url.lastPathComponent).") }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, self, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw CameraError("Could not write \(url.lastPathComponent).") }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
