import CoreGraphics
import UIKit

/// Renders PDF pages to images off the main thread, with an Apple Books–style
/// night mode: text pages become light-on-black, while colour (covers,
/// illustrations, coloured headings) is left alone.
actor PageRenderer {
    private let doc: CGPDFDocument?
    private let cache = NSCache<NSString, UIImage>()

    init(url: URL) {
        doc = CGPDFDocument(url as CFURL)
        cache.countLimit = 12
        cache.totalCostLimit = 220 * 1024 * 1024   // keep page images under ~220 MB
    }

    var pageCount: Int { doc?.numberOfPages ?? 0 }

    /// Aspect ratio (width / height) of a page, 0-based index.
    func aspect(of index: Int) -> CGFloat {
        guard let page = doc?.page(at: index + 1) else { return 2.0 / 3.0 }
        let r = Self.box(page)
        return r.height > 0 ? r.width / r.height : 2.0 / 3.0
    }

    func image(index: Int, fitting size: CGSize, scale: CGFloat, dark: Bool) -> UIImage? {
        let key = "\(index)|\(Int(size.width))x\(Int(size.height))|\(dark)|\(Int(scale * 10))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let page = doc?.page(at: index + 1), size.width > 1, size.height > 1 else { return nil }

        let box = Self.box(page)
        let fit = min(size.width / box.width, size.height / box.height)
        let w = Int((box.width * fit * scale).rounded())
        let h = Int((box.height * fit * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
        let crop = page.getBoxRect(.cropBox)
        switch ((page.rotationAngle % 360) + 360) % 360 {
        case 90:
            ctx.translateBy(x: 0, y: box.height); ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: box.width, y: 0); ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.clip(to: crop)
        ctx.drawPDFPage(page)

        if dark, let data = ctx.data {
            Self.darken(data.assumingMemoryBound(to: UInt8.self), count: w * h)
        }
        guard let cg = ctx.makeImage() else { return nil }
        let img = UIImage(cgImage: cg, scale: scale, orientation: .up)
        cache.setObject(img, forKey: key, cost: w * h * 4)
        return img
    }

    func clear() { cache.removeAllObjects() }

    private static func box(_ page: CGPDFPage) -> CGRect {
        var r = page.getBoxRect(.cropBox)
        if page.rotationAngle % 180 != 0 { r = CGRect(x: r.minX, y: r.minY, width: r.height, height: r.width) }
        return r
    }

    private static func darken(_ p: UnsafeMutablePointer<UInt8>, count: Int) {
        // Is this mostly a white text page? (covers / full-page art are left as-is)
        var light = 0, total = 0
        var i = 0
        let stride = 4 * 61
        let n = count * 4
        while i < n {
            total += 1
            if p[i] > 225 && p[i + 1] > 225 && p[i + 2] > 225 { light += 1 }
            i += stride
        }
        guard total > 0, Double(light) / Double(total) >= 0.45 else { return }

        i = 0
        while i < n {
            let r = p[i], g = p[i + 1], b = p[i + 2]
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            if mx &- mn < 64 {
                // invert greys: white paper -> black, black ink -> soft white
                p[i] = UInt8(Double(255 &- r) * 0.93)
                p[i + 1] = UInt8(Double(255 &- g) * 0.93)
                p[i + 2] = UInt8(Double(255 &- b) * 0.93)
            }
            i += 4
        }
    }
}
