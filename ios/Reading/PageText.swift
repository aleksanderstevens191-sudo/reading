import PDFKit
import Vision

/// Gets the words on a page: the PDF's own text if it has any, otherwise
/// on-device OCR (for scanned books).
enum PageText {
    static func text(of doc: PDFDocument, index: Int) async -> String {
        guard let page = doc.page(at: index) else { return "" }
        let raw = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count > 40 { return clean(raw) }

        // Scanned page → recognise text from an image of it
        let bounds = page.bounds(for: .mediaBox)
        let scale = 1600 / max(bounds.width, 1)
        let img = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cg = img.cgImage else { return raw }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: cg).perform([req])
                    let lines = req.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                    cont.resume(returning: clean(lines.joined(separator: "\n")))
                } catch {
                    cont.resume(returning: raw)
                }
            }
        }
    }

    /// Joins hyphenated line breaks and tidies whitespace.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-\n", with: "")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
