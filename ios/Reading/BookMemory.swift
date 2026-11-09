import Foundation
import PDFKit

/// A note the AI wrote about part of the book. Level 0 covers a few pages;
/// higher levels combine several notes so long books still fit.
struct MemoryNote: Codable, Equatable {
    var level: Int
    var start: Int      // first page (0-based)
    var end: Int        // last page (0-based, inclusive)
    var text: String
}

/// Reads the book in the background (while it's open) and keeps short notes,
/// so the AI knows the story so far when you ask about a page.
/// Notes are saved, so each book only needs reading once.
@MainActor
@Observable
final class BookMemory {
    let bookID: String
    let title: String
    let doc: PDFDocument
    let total: Int
    var kind: BookKind

    private(set) var notes: [MemoryNote] = []
    private(set) var working = false
    /// The reader's current page; notes are made up to a little past it.
    private(set) var position = 0

    static let chunkPages = 4
    static let groupSize = 6
    static let lookahead = 0
    static let contextWords = 550

    private var stop = StopFlag()
    private var task: Task<Void, Never>?
    private var pauses = 0
    private var primed: String?
    private var debounce: Task<Void, Never>?
    var lastWarm = "no warm"


    private var fileURL: URL {
        let dir = Library.docs.appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bookID).json")
    }

    init(book: Book, doc: PDFDocument) {
        bookID = book.id
        title = book.title
        self.doc = doc
        total = doc.pageCount
        kind = book.resolvedKind
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([MemoryNote].self, from: data) {
            notes = saved
        }
    }

    /// How many pages from the start have notes.
    var pagesRead: Int { (notes.filter { $0.level == 0 }.map(\.end).max() ?? -1) + 1 }

    /// Notes cover everything before this page.
    func isReady(for page: Int) -> Bool { pagesRead >= page }

    // MARK: Control

    func setPosition(_ page: Int, immediately: Bool = false) {
        position = page
        debounce?.cancel()
        if immediately { kick(); return }
        // Wait until the reader settles on a page before doing work for it.
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.kick() }
        }
    }

    /// Stop background work (e.g. while the reader is waiting on an answer).
    func pause() async {
        pauses += 1
        stop.value = true
        await task?.value
    }

    func resume() {
        pauses = max(0, pauses - 1)
        kick()
    }

    /// Waits until the current background work finishes (used by tests).
    func waitIdle() async { await task?.value }

    func shutdown() {
        pauses += 1
        stop.value = true
    }

    private func kick() {
        guard task == nil, pauses == 0, LocalLLM.isAvailable, LocalLLM.findModel() != nil else { return }
        let flag = StopFlag()
        stop = flag
        task = Task { [weak self] in
            await self?.loop(flag)
            self?.task = nil
            self?.working = false
        }
    }

    private func loop(_ flag: StopFlag) async {
        while !flag.value {
            if let job = nextJob() {
                working = true
                primed = nil   // note-taking replaces what the AI has in memory
                if !(await run(job, flag)) { return }
                continue
            }
            working = false
            let pos = position
            await primeCurrentPage(pos, flag)
            if flag.value || position == pos { return }
        }
    }

    /// Pre-read the instructions, story so far and the page on screen, so that
    /// tapping Explain only has to read the short request.
    private func primeCurrentPage(_ page: Int, _ flag: StopFlag) async {
        guard page < total else { return }
        let current = await PageText.text(of: doc, index: page)
        guard !current.isEmpty else { return }
        let previous = page > 0 ? await PageText.text(of: doc, index: page - 1) : ""
        let system = Self.systemPrompt(title: title, kind: kind, context: context(before: page))
        let prefix = LocalLLM.format([Turn(role: "system", text: system)], openModelTurn: false)
            + "<|turn>user\n" + ExplainView.pageBlock(page: page + 1, current: current, previous: previous)
        guard prefix != primed else { return }
        let stats = await Task.detached(priority: .utility) {
            try? await LocalLLM.shared.prime(raw: prefix, stop: flag)
        }.value
        lastWarm = "warm: reused \(stats?.reusedTokens ?? -1), read \(stats?.promptTokens ?? -1), stopped \(flag.value)"
        if stats != nil && !flag.value { primed = prefix }
    }

    // MARK: Jobs

    private enum Job {
        case chunk(Int, Int)
        case merge(Int, [MemoryNote])
    }

    private func nextJob() -> Job? {
        // Combine finished groups of notes (cheap, keeps long books compact).
        for level in 0..<3 {
            let items = notes.filter { $0.level == level }.sorted { $0.start < $1.start }
            var i = 0
            while i + Self.groupSize <= items.count {
                let group = Array(items[i..<(i + Self.groupSize)])
                let hasParent = notes.contains { $0.level == level + 1 && $0.start == group[0].start }
                if !hasParent { return .merge(level + 1, group) }
                i += Self.groupSize
            }
        }
        // Read the next few pages, up to a little past where the reader is.
        let next = pagesRead
        if next + Self.chunkPages <= min(total, position + Self.lookahead) {
            return .chunk(next, min(total - 1, next + Self.chunkPages - 1))
        }
        return nil
    }

    /// Returns false if it was stopped.
    private func run(_ job: Job, _ flag: StopFlag) async -> Bool {
        let turns: [Turn]
        let level: Int, start: Int, end: Int
        switch job {
        case .chunk(let a, let b):
            level = 0; start = a; end = b
            var text = ""
            let perPage = 6000 / (b - a + 1)
            for p in a...b {
                let t = await PageText.text(of: doc, index: p)
                if !t.isEmpty { text += "[Page \(p + 1)]\n" + String(t.prefix(perPage)) + "\n\n" }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                save(MemoryNote(level: 0, start: a, end: b, text: "(no words on these pages)"))
                return true
            }
            let what = kind == .novel ? "pages" : "pages (speech bubbles read by text recognition, so the order may be jumbled)"
            turns = [
                Turn(role: "system", text: "You take notes on a book for a reading assistant. Summarize the \(what): who appears (full names), what happens, and any important places, objects or terms. At most 80 words. Plain text, no preamble."),
                Turn(role: "user", text: "Book: \"\(title)\". Pages \(a + 1)–\(b + 1):\n\n\(text)"),
            ]
        case .merge(let lvl, let group):
            level = lvl; start = group.first!.start; end = group.last!.end
            let joined = group.map { "Pages \($0.start + 1)–\($0.end + 1): \($0.text)" }.joined(separator: "\n")
            turns = [
                Turn(role: "system", text: "Combine these consecutive notes about a book into one summary of at most 90 words. Keep the names and the key events in order. Plain text, no preamble."),
                Turn(role: "user", text: joined),
            ]
        }

        let collector = TextCollector()
        let finished = await Task.detached(priority: .utility) { () -> Bool in
            do {
                _ = try await LocalLLM.shared.generate(turns: turns, maxTokens: 160, stop: flag, background: true) { collector.append($0) }
                return !flag.value
            } catch {
                return false
            }
        }.value
        guard finished else { return false }
        let summary = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        save(MemoryNote(level: level, start: start, end: end, text: summary.isEmpty ? "(nothing notable)" : summary))
        return true
    }

    private func save(_ note: MemoryNote) {
        notes.removeAll { $0.level == note.level && $0.start == note.start }
        notes.append(note)
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Context for questions

    /// A compact "story so far" for everything before `page`.
    func context(before page: Int) -> String {
        var chosen = notes.filter { $0.level == 0 && $0.end < page }.sorted { $0.start < $1.start }
        func words(_ ns: [MemoryNote]) -> Int { ns.reduce(0) { $0 + $1.text.split(separator: " ").count } }

        while words(chosen) > Self.contextWords {
            // Swap the oldest group of detailed notes for its combined summary.
            let parents = notes.filter { $0.level >= 1 && $0.end < page }.sorted { ($0.start, $0.level) < ($1.start, $1.level) }
            var replaced = false
            for parent in parents {
                let inside = chosen.filter { $0.start >= parent.start && $0.end <= parent.end }
                if inside.count >= 2 {
                    chosen.removeAll { $0.start >= parent.start && $0.end <= parent.end }
                    chosen.append(parent)
                    chosen.sort { $0.start < $1.start }
                    replaced = true
                    break
                }
            }
            if !replaced { chosen.removeFirst() }
        }
        return chosen.map { "Pages \($0.start + 1)–\($0.end + 1): \($0.text)" }.joined(separator: "\n")
    }

    /// The fixed start of every question. Kept identical so the AI can reuse it.
    static func systemPrompt(title: String, kind: BookKind, context: String) -> String {
        let what: String
        switch kind {
        case .novel: what = "the book"
        case .manga: what = "the manga"
        case .comic: what = "the comic"
        }
        var s = """
        You are a friendly reading companion inside an e-reader. The reader is reading \(what) "\(title)". \
        Explain clearly in plain, simple English, like a good teacher. Keep answers short: a few short paragraphs or bullet points. \
        Start straight away, with no greeting. Use the story-so-far notes and the pages shown. \
        If something isn't covered there, say you're not sure instead of guessing. Never make up plot details.
        """
        if kind != .novel {
            s += " The page text comes from text recognition on the artwork, so speech bubbles may be out of order or have small errors."
        }
        s += "\n\nStory so far (notes on the pages before this one):\n"
        s += context.isEmpty ? "(Nothing yet: this is the start of the book, or the notes aren't ready.)" : context
        return s
    }
}

/// Collects streamed text from a background task.
final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    func append(_ s: String) { lock.lock(); _text += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return _text }
}
