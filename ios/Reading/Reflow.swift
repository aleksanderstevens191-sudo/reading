import PDFKit
import UIKit
import Vision

// Kindle-style reading for PDFs: the words are pulled out of the PDF, rebuilt
// into paragraphs, and laid out again at a comfortable size that fills the
// screen, instead of showing a tiny picture of the printed page.

/// One paragraph of the book, and the PDF page it starts on (0-based).
struct ReflowPara: Codable {
    var text: String
    var heading: Bool
    var page: Int
}

/// The book's text as paragraphs, cached in Documents/Text/<book id>.json.
final class ReflowSource: @unchecked Sendable {
    static let version = 2   // 2: scanned books are read with on-device text recognition
    let paras: [ReflowPara]
    /// Character offset where each paragraph starts in the joined text.
    let offsets: [Int]
    /// False for scanned books with no text layer: those stay as page images.
    let hasText: Bool

    private struct Stored: Codable { var version: Int; var paras: [ReflowPara] }

    init(paras: [ReflowPara]) {
        self.paras = paras
        var o: [Int] = []
        var n = 0
        for p in paras { o.append(n); n += (p.text as NSString).length + 1 }
        offsets = o
        hasText = paras.reduce(0) { $0 + $1.text.count } > 1500
    }

    /// Offset of the first paragraph that starts on or after a PDF page.
    func offset(forPDFPage page: Int) -> Int {
        guard let i = paras.firstIndex(where: { $0.page >= page }) else { return offsets.last ?? 0 }
        return offsets[i]
    }

    /// PDF page that the text at an offset came from.
    func pdfPage(forOffset off: Int) -> Int {
        var lo = 0, hi = offsets.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= off { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return paras.isEmpty ? 0 : paras[best].page
    }

    static func cacheURL(_ id: String) -> URL {
        Library.docs.appendingPathComponent("Text", isDirectory: true).appendingPathComponent("\(id).json")
    }

    /// Loads the cached text, or extracts it from the PDF (first open only).
    static func load(bookID: String, url: URL, title: String,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ReflowSource {
        let cache = cacheURL(bookID)
        if let data = try? Data(contentsOf: cache),
           let s = try? JSONDecoder().decode(Stored.self, from: data), s.version == version {
            return ReflowSource(paras: s.paras)
        }
        let paras = await Task.detached(priority: .userInitiated) {
            ReflowExtractor.paragraphs(url: url, title: title, progress: progress)
        }.value
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(version: version, paras: paras)) {
            try? data.write(to: cache, options: .atomic)
        }
        return ReflowSource(paras: paras)
    }
}

/// Rebuilds paragraphs from the lines on each PDF page.
enum ReflowExtractor {
    struct Line {
        var text: String
        var minX: CGFloat, maxX: CGFloat
        var top: CGFloat            // distance from the top of the page
        var pageH: CGFloat
    }

    static func lines(of page: PDFPage) -> [Line] {
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, let sel = page.selection(for: box) else { return [] }
        return sel.selectionsByLine().compactMap { l in
            let s = (l.string ?? "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            let b = l.bounds(for: page)
            return Line(text: s, minX: b.minX - box.minX, maxX: b.maxX - box.minX,
                        top: box.maxY - b.maxY, pageH: box.height)
        }
    }

    // MARK: Scanned books

    private final class Pages: @unchecked Sendable {
        var lines: [[Line]]
        var done = 0
        let lock = NSLock()
        init(_ n: Int) { lines = Array(repeating: [], count: n) }
    }

    /// Text recognition (on device) for every page, a few pages at a time.
    static func recognize(url: URL, count: Int, progress: @escaping @Sendable (Double) -> Void) -> [[Line]] {
        let out = Pages(count)
        let langs = languages()
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 4))
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            guard let doc = CGPDFDocument(url as CFURL) else { return }   // one per thread
            var i = w
            while i < count {
                let ls = autoreleasepool { recognize(doc: doc, index: i, languages: langs) }
                out.lock.lock()
                out.lines[i] = ls
                out.done += 1
                let d = out.done
                out.lock.unlock()
                progress(Double(d) / Double(count))
                i += workers
            }
        }
        return out.lines
    }

    /// The reader's own languages, so the recogniser doesn't guess (it turns smudges into "ằ").
    static func languages() -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let supported = Set((try? req.supportedRecognitionLanguages()) ?? [])
        let mine = Locale.preferredLanguages.filter { supported.contains($0) }
        return mine.isEmpty ? ["en-US"] : mine
    }

    static func recognize(doc: CGPDFDocument, index: Int, languages: [String]) -> [Line] {
        guard let page = doc.page(at: index + 1) else { return [] }
        let box = page.getBoxRect(.cropBox)
        let turned = (page.rotationAngle / 90) % 2 != 0
        let W = turned ? box.height : box.width, H = turned ? box.width : box.height
        guard W > 1, H > 1 else { return [] }
        let scale = 2000 / max(W, H)
        let pw = Int(W * scale), ph = Int(H * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: W, height: H),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let img = ctx.makeImage() else { return [] }

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = languages
        do { try VNImageRequestHandler(cgImage: img).perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { o -> Line? in
            let t = cleanRecognized(o.topCandidates(1).first?.string ?? "")
            guard !t.isEmpty else { return nil }
            let b = o.boundingBox   // 0…1, origin bottom-left
            return Line(text: t, minX: b.minX * W, maxX: b.maxX * W, top: (1 - b.maxY) * H, pageH: H)
        }
        .sorted { abs($0.top - $1.top) > 3 ? $0.top < $1.top : $0.minX < $1.minX }
    }

    /// Drops scan specks the recogniser reads as letters at the end of a line ("record_ằ").
    static func cleanRecognized(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "_", with: "")
        let latin = t.unicodeScalars.filter { $0.value < 0x250 }.count
        // In a Latin-script line, the last word is cut at the first odd letter ("himạẠại" → "him").
        if latin * 2 > t.unicodeScalars.count {
            let scalars = Array(t.unicodeScalars)
            let wordStart = (scalars.lastIndex { $0 == " " }).map { $0 + 1 } ?? 0
            if let bad = scalars[wordStart...].firstIndex(where: { $0.value >= 0x250 && $0.properties.isAlphabetic }) {
                var u = String.UnicodeScalarView()
                u.append(contentsOf: scalars[..<bad])
                t = String(u)
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Letters only, lowercased: "The Old Man and the Sea  11" → "theoldmanandthesea".
    static func key(_ s: String) -> String { String(s.lowercased().filter(\.isLetter)) }

    /// A running title, allowing for a couple of misread letters on scans.
    static func isRunning(_ k: String, _ running: Set<String>) -> Bool {
        if running.contains(k) { return true }
        guard k.count >= 8 else { return false }
        return running.contains { r in abs(r.count - k.count) <= 2 && distance(r, k) <= max(2, r.count / 8) }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static func isPageNumber(_ s: String) -> Bool {
        s.range(of: #"^[\s\-–—.\[\]()]*\d{1,4}[\s\-–—.\[\]()]*$"#, options: .regularExpression) != nil
    }

    static func paragraphs(url: URL, title: String, progress: @escaping @Sendable (Double) -> Void) -> [ReflowPara] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var pages = (0..<doc.pageCount).map { i in doc.page(at: i).map(lines(of:)) ?? [] }
        // A scan has no text inside: read the words off the page images instead.
        let chars = pages.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
        if chars < doc.pageCount * 100 {
            pages = recognize(url: url, count: doc.pageCount, progress: progress)
        }

        // Running heads and footers (book or chapter title repeated at the top
        // or bottom of most pages) and page numbers aren't part of the text.
        var counts: [String: Int] = [:]
        for ls in pages {
            var seen = Set<String>()
            for l in ls where l.top < l.pageH * 0.15 || l.top > l.pageH * 0.85 {
                let k = key(l.text)
                if k.count >= 3, seen.insert(k).inserted { counts[k, default: 0] += 1 }
            }
        }
        let threshold = max(3, pages.count / 6)
        var running = Set(counts.filter { $0.value >= threshold }.keys)
        let titleKey = key(title)
        if titleKey.count >= 3 { running.insert(titleKey) }

        var out: [ReflowPara] = []
        var cur = ""
        var curPage = 0
        var prevShort = true   // the last line ended a paragraph

        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(ReflowPara(text: t, heading: false, page: curPage)) }
            cur = ""
        }
        func append(_ s: String, page: Int) {
            if cur.isEmpty { cur = s; curPage = page; return }
            if cur.hasSuffix("\u{00AD}") {
                cur.removeLast(); cur += s
            } else if cur.hasSuffix("-"), cur.dropLast().last?.isLetter == true, s.first?.isLowercase == true {
                cur.removeLast(); cur += s          // word split across lines: "pros-" + "ecutor"
            } else if cur.hasSuffix("—") || cur.hasSuffix("–") {
                cur += s
            } else {
                cur += " " + s
            }
        }

        for (p, all) in pages.enumerated() {
            let ls = all.filter { l in
                let edge = l.top < l.pageH * 0.15 || l.top > l.pageH * 0.85
                if edge && isPageNumber(l.text) { return false }
                if edge && l.text.count <= 4 { return false }    // page numbers misread on scans ("I I")
                if edge && isRunning(key(l.text), running) { return false }
                return true
            }
            guard !ls.isEmpty else { continue }

            // Where the text block sits on this page.
            let widest = ls.map { $0.maxX - $0.minX }.max() ?? 1
            let full = ls.filter { $0.maxX - $0.minX >= widest * 0.6 }
            let left = full.map(\.minX).min() ?? 0
            let right = full.map(\.maxX).max() ?? widest
            let bodyW = max(right - left, 1)
            let gaps = zip(ls.dropFirst(), ls).map { $0.top - $1.top }.filter { $0 > 0 }.sorted()
            let lineH = gaps.isEmpty ? 14 : gaps[gaps.count / 2]

            var prevIndent: CGFloat = 0
            var prevStarted = false   // the previous line began a paragraph
            for (i, l) in ls.enumerated() {
                let indent = l.minX - left
                let trailing = right - l.maxX
                // Well in from both edges (much more than a paragraph indent) and roughly centred.
                let centered = indent > bodyW * 0.15 && trailing > bodyW * 0.15
                    && abs(indent - trailing) < bodyW * 0.12 && l.text.count < 70
                let gap = i > 0 ? l.top - ls[i - 1].top : 0
                let indented = indent > bodyW * 0.02 && indent < bodyW * 0.3

                if centered {
                    // Chapter titles and section breaks get their own line.
                    flush()
                    out.append(ReflowPara(text: l.text, heading: true, page: p))
                    prevShort = true
                    prevIndent = 0
                    prevStarted = false
                    continue
                }
                // A line starting in lowercase carries on the sentence, even after a short line or a drop cap.
                let continues = l.text.first?.isLowercase == true && !indented
                // An indented line starts a paragraph, unless it follows an indented line that
                // wasn't a paragraph start (a block quote).
                let indentStarts = indented && (prevIndent <= bodyW * 0.02 || prevStarted)
                let newPara = gap > lineH * 3 || (!continues && (gap > lineH * 1.6 || prevShort || indentStarts))
                if newPara { flush() }
                append(l.text, page: p)
                prevShort = trailing > bodyW * 0.12
                prevIndent = indent
                prevStarted = newPara
            }
        }
        flush()
        return out
    }
}

/// The reflowed book split into screen-sized pages for one text size and screen.
final class ReflowLayout: @unchecked Sendable {
    struct Key: Hashable {
        var book: String
        var width: Int
        var height: Int
        var fontSize: Double
    }

    let key: Key
    let source: ReflowSource
    let size: CGSize                                         // text area of one page
    let rects: [PageSlotController.Side: CGRect]             // where it sits on each side of the book
    let ranges: [NSRange]                                    // characters on each page
    private let text: NSAttributedString

    var pageCount: Int { ranges.count }

    init(source: ReflowSource, key: Key, size: CGSize, rects: [PageSlotController.Side: CGRect]) {
        self.key = key
        self.source = source
        self.size = size
        self.rects = rects
        text = Self.attributed(source, fontSize: CGFloat(key.fontSize))

        // Pour the text into page-sized boxes one after another.
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        var out: [NSRange] = []
        let glyphs = lm.numberOfGlyphs
        while true {
            let tc = NSTextContainer(size: size)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let g = lm.glyphRange(for: tc)
            if g.length == 0 { break }
            out.append(lm.characterRange(forGlyphRange: g, actualGlyphRange: nil))
            if NSMaxRange(g) >= glyphs { break }
        }
        ranges = out.isEmpty ? [NSRange(location: 0, length: 0)] : out
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        if let f = UIFont(name: bold ? "Charter-Bold" : "Charter-Roman", size: size) { return f }
        let d = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
        return UIFont(descriptor: d.withDesign(.serif) ?? d, size: size)
    }

    private static func attributed(_ source: ReflowSource, fontSize s: CGFloat) -> NSAttributedString {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = s * 0.34
        body.firstLineHeadIndent = s * 1.6
        body.hyphenationFactor = 0.6
        body.alignment = .natural

        let head = NSMutableParagraphStyle()
        head.alignment = .center
        head.lineSpacing = s * 0.3
        head.paragraphSpacingBefore = s * 1.2
        head.paragraphSpacing = s * 0.9
        head.hyphenationFactor = 0

        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: font(s), .paragraphStyle: body]
        let headAttrs: [NSAttributedString.Key: Any] = [.font: font(s * 1.12, bold: true), .paragraphStyle: head]
        let out = NSMutableAttributedString()
        for (i, p) in source.paras.enumerated() {
            let t = i + 1 < source.paras.count ? p.text + "\n" : p.text
            out.append(NSAttributedString(string: t, attributes: p.heading ? headAttrs : bodyAttrs))
        }
        return out
    }

    // MARK: Positions

    /// The page that holds a character offset.
    func page(forOffset off: Int) -> Int {
        var lo = 0, hi = ranges.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location <= off { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    func page(forPDFPage p: Int) -> Int { page(forOffset: source.offset(forPDFPage: p)) }
    func offset(ofPage i: Int) -> Int { ranges[max(0, min(i, ranges.count - 1))].location }
    func firstPDFPage(ofPage i: Int) -> Int { source.pdfPage(forOffset: offset(ofPage: i)) }
    func lastPDFPage(ofPage i: Int) -> Int {
        let r = ranges[max(0, min(i, ranges.count - 1))]
        return source.pdfPage(forOffset: max(r.location, NSMaxRange(r) - 1))
    }

    // MARK: Drawing

    func image(page i: Int, scale: CGFloat, dark: Bool) -> UIImage? {
        guard ranges.indices.contains(i), size.width > 1 else { return nil }
        let r = ranges[i]
        let all = text.string as NSString
        let sub = NSMutableAttributedString(attributedString: text.attributedSubstring(from: r))
        let subStr = sub.string as NSString

        // A page that starts mid-paragraph has no first-line indent.
        if r.location > 0, all.character(at: r.location - 1) != 10, sub.length > 0,
           let ps = sub.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let m = ps.mutableCopy() as? NSMutableParagraphStyle {
            m.firstLineHeadIndent = m.headIndent
            m.paragraphSpacingBefore = 0
            sub.addAttribute(.paragraphStyle, value: m, range: subStr.paragraphRange(for: NSRange(location: 0, length: 0)))
        }
        // A word split across pages keeps its hyphen.
        let end = NSMaxRange(r)
        if end < all.length, end > 0,
           let a = Unicode.Scalar(all.character(at: end - 1)), let b = Unicode.Scalar(all.character(at: end)),
           CharacterSet.letters.contains(a), CharacterSet.letters.contains(b) {
            sub.append(NSAttributedString(string: "-", attributes: sub.attributes(at: max(sub.length - 1, 0), effectiveRange: nil)))
        }
        let color = dark ? UIColor(white: 0.86, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        sub.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: sub.length))

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let storage = NSTextStorage(attributedString: sub)
            let lm = NSLayoutManager()
            storage.addLayoutManager(lm)
            let tc = NSTextContainer(size: CGSize(width: size.width, height: size.height + 400))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let g = lm.glyphRange(for: tc)
            lm.drawGlyphs(forGlyphRange: g, at: .zero)
        }
    }
}
