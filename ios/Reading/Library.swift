import Foundation
import PDFKit
import UIKit

enum BookKind: String, Codable, CaseIterable {
    case novel, manga, comic

    var label: String {
        switch self {
        case .novel: return "Book"
        case .manga: return "Manga (right to left)"
        case .comic: return "Comic (left to right)"
        }
    }
    var rightToLeft: Bool { self == .manga }
    /// Text books get the white-on-black night mode; artwork is left as drawn.
    var invertsInDarkMode: Bool { self == .novel }
}

struct Book: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var fileName: String
    var pageCount: Int
    var page: Int = 0          // 0-based index of the first page on screen
    var lastSeen: Int = 0      // 0-based index of the last page on screen
    var addedAt = Date()
    var openedAt: Date?
    var kind: BookKind?

    var resolvedKind: BookKind { kind ?? .novel }

    var progress: Double {
        guard pageCount > 1 else { return 0 }
        return Double(lastSeen + 1) / Double(pageCount)
    }
}

/// Keeps the list of books in Documents/library.json and the PDFs in Documents/Books.
@Observable
final class Library {
    var books: [Book] = []
    var importing: String?

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let booksDir = docs.appendingPathComponent("Books", isDirectory: true)
    static let coversDir = docs.appendingPathComponent("Covers", isDirectory: true)
    private static let indexURL = docs.appendingPathComponent("library.json")

    init() {
        for dir in [Self.booksDir, Self.coversDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([Book].self, from: data) {
            books = saved
        }
        sort()
    }

    func fileURL(_ book: Book) -> URL { Self.booksDir.appendingPathComponent(book.fileName) }
    func coverURL(_ book: Book) -> URL { Self.coversDir.appendingPathComponent("\(book.id).jpg") }

    func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    private func sort() {
        books.sort { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }
    }

    func update(_ book: Book) {
        if let i = books.firstIndex(where: { $0.id == book.id }) { books[i] = book }
        save()
    }

    func markOpened(_ id: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].openedAt = Date()
        save()
    }

    func remove(_ book: Book) {
        try? FileManager.default.removeItem(at: fileURL(book))
        try? FileManager.default.removeItem(at: coverURL(book))
        books.removeAll { $0.id == book.id }
        save()
    }

    /// Copies a PDF into the library. Returns the book (existing one if it's a duplicate).
    @discardableResult
    func importPDF(from url: URL) -> Book? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = url.lastPathComponent
        if let dupe = books.first(where: { $0.title == Self.cleanTitle(name) && (try? fileURL($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) == size }) {
            return dupe
        }

        let id = UUID().uuidString
        let dest = Self.booksDir.appendingPathComponent("\(id).pdf")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        guard let doc = PDFDocument(url: dest), doc.pageCount > 0 else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        var title = Self.cleanTitle(name)
        if let t = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           t.count > 2, t.range(of: #"\.(docx?|pdf|indd)|untitled|microsoft"#, options: [.regularExpression, .caseInsensitive]) == nil {
            title = t
        }

        var book = Book(id: id, title: title, fileName: dest.lastPathComponent, pageCount: doc.pageCount)
        book.kind = Self.detectKind(doc)
        if let page = doc.page(at: 0) {
            let thumb = page.thumbnail(of: CGSize(width: 420, height: 630), for: .mediaBox)
            try? thumb.jpegData(compressionQuality: 0.85)?.write(to: coverURL(book))
        }
        books.insert(book, at: 0)
        save()
        return book
    }

    /// Image-only PDFs (scans of manga/comics) have almost no text layer.
    static func detectKind(_ doc: PDFDocument) -> BookKind {
        let pages = Array(1..<min(doc.pageCount, 13))
        guard !pages.isEmpty else { return .novel }
        let chars = pages.reduce(0) { $0 + (doc.page(at: $1)?.string?.count ?? 0) }
        return chars / pages.count < 60 ? .manga : .novel
    }

    static func cleanTitle(_ fileName: String) -> String {
        var s = fileName
        if s.lowercased().hasSuffix(".pdf") { s = String(s.dropLast(4)) }
        return s.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
    }
}
