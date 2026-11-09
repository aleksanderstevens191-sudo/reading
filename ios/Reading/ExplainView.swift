import PDFKit
import SwiftUI

/// Side panel that asks the on-device model about the page you're on.
/// It knows the story so far (from BookMemory) and you can ask follow-ups.
struct ExplainView: View {
    let title: String
    let kind: BookKind
    let doc: PDFDocument
    let pages: [Int]            // pages on screen (0-based)
    let memory: BookMemory?

    @State private var target: Int?
    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var turns: [Turn] = []          // the conversation so far, for follow-ups
    @State private var convoPage: Int?
    @State private var phase: Phase = .idle
    @State private var stop = StopFlag()
    @State private var job: Task<Void, Never>?
    @FocusState private var askFocused: Bool

    struct Exchange: Identifiable {
        let id = UUID()
        var question: String
        var answer: String = ""
        var stats: String = ""
    }

    enum Phase: Equatable {
        case idle, loading, reading, writing, done
        case failed(String)
    }

    enum Ask {
        case explain, summarize, words, question(String)
        var label: String {
            switch self {
            case .explain: return "Explain this page"
            case .summarize: return "Summarize"
            case .words: return "Hard words"
            case .question(let q): return q
            }
        }
    }

    private var page: Int { target.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first ?? 0 }
    private var busy: Bool { [.loading, .reading, .writing].contains(phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Explain", systemImage: "sparkles").font(.headline)
                Spacer()
                if pages.count > 1 {
                    Picker("Page", selection: Binding(get: { page }, set: { target = $0 })) {
                        ForEach(pages, id: \.self) { Text("Page \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text("Page \(page + 1)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 8)

            if !LocalLLM.isAvailable {
                notice("The AI runs on your iPad itself. It isn’t available in the simulator.")
            } else if LocalLLM.findModel() == nil {
                notice("The AI model isn’t on this device yet. Connect the iPad to your Mac and copy the .gguf model into Reading’s Models folder (Finder → iPad → Files → Reading).")
            } else {
                memoryStatus
                actions
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if exchanges.isEmpty { intro }
                            ForEach(exchanges) { ex in exchangeView(ex).id(ex.id) }
                            statusLine
                        }
                        .padding(18)
                    }
                    .onChange(of: exchanges.count) { _, _ in
                        if let last = exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                    }
                }
                askBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: pages) { _, _ in if !busy { target = nil } }
        .onDisappear { stop.value = true }
    }

    // MARK: Pieces

    @ViewBuilder private var memoryStatus: some View {
        if let memory {
            let read = min(memory.pagesRead, memory.total)
            let ready = memory.isReady(for: page)
            HStack(spacing: 6) {
                if memory.working && !ready { ProgressView().controlSize(.mini) }
                Image(systemName: ready ? "book.closed.fill" : "book.closed")
                    .font(.caption)
                Text(ready
                     ? "Knows the story up to here"
                     : "Getting to know the book: read \(read) of \(page) pages so far")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.bottom, 10)
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Explain this page", "text.magnifyingglass") { run(.explain) }
                chip("Summarize", "list.bullet") { run(.summarize) }
                chip("Hard words", "character.book.closed") { run(.words) }
            }
            .padding(.horizontal, 18).padding(.bottom, 12)
        }
        .disabled(busy)
    }

    private var intro: some View {
        Text("Tap a button above or ask anything about this page: who someone is, what just happened, what a word means. You can ask follow-up questions. Everything runs on this iPad, no internet needed.")
            .font(.subheadline).foregroundStyle(.secondary)
    }

    private func exchangeView(_ ex: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ex.question)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            if !ex.answer.isEmpty {
                Text(Self.render(ex.answer))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !ex.stats.isEmpty {
                Text(ex.stats).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            TextField(exchanges.isEmpty ? "Ask about this page…" : "Ask a follow-up…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($askFocused)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            if busy {
                Button { stop.value = true } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop")
            } else {
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(12)
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .loading: progress("Waking up the AI… (first time takes a few seconds)")
        case .reading: progress("Reading page \(page + 1)…")
        case .failed(let msg): Text(msg).foregroundStyle(.red).font(.subheadline)
        default: EmptyView()
        }
    }

    private func progress(_ s: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(s).font(.subheadline).foregroundStyle(.secondary) }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func notice(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(.secondary).padding(18)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        question = ""
        askFocused = false
        run(.question(q))
    }

    // MARK: Running the model

    private func run(_ ask: Ask) {
        job?.cancel()
        let stop = StopFlag()
        self.stop = stop
        let index = page

        // A typed question continues the conversation about the same page.
        let followUp: Bool = {
            if case .question = ask { return convoPage == index && !turns.isEmpty }
            return false
        }()

        job = Task {
            phase = await LocalLLM.shared.loaded ? .reading : .loading
            await memory?.pause()
            defer { memory?.resume() }

            var convo: [Turn]
            if followUp {
                convo = turns + [Turn(role: "user", text: ask.label)]
            } else {
                let current = await PageText.text(of: doc, index: index)
                let previous = index > 0 ? await PageText.text(of: doc, index: index - 1) : ""
                if current.isEmpty {
                    phase = .failed("I couldn’t find any words on this page.")
                    return
                }
                let context = memory?.context(before: index) ?? ""
                let system = BookMemory.systemPrompt(title: title, kind: kind, context: context)
                convo = [Turn(role: "system", text: system),
                         Turn(role: "user", text: Self.userPrompt(page: index + 1, current: current, previous: previous, ask: ask))]
                exchanges = []
            }
            exchanges.append(Exchange(question: ask.label))
            let slot = exchanges.count - 1

            let (stream, cont) = AsyncStream.makeStream(of: String.self)
            let send = convo
            let worker = Task.detached(priority: .userInitiated) { () -> Result<LLMStats, Error> in
                defer { cont.finish() }
                do {
                    try await LocalLLM.shared.load()
                    cont.yield("\u{0}reading")
                    let stats = try await LocalLLM.shared.generate(turns: send, stop: stop) { cont.yield($0) }
                    return .success(stats)
                } catch {
                    return .failure(error)
                }
            }
            for await piece in stream {
                if piece == "\u{0}reading" { phase = .reading; continue }
                if phase != .writing { phase = .writing }
                exchanges[slot].answer += piece
            }
            switch await worker.value {
            case .success(let s):
                phase = .done
                exchanges[slot].stats = String(format: "Started answering after %.1f s", s.promptSeconds)
                if exchanges[slot].answer.isEmpty { exchanges[slot].answer = "(Stopped.)" }
                turns = convo + [Turn(role: "model", text: exchanges[slot].answer)]
                convoPage = index
                // keep follow-ups from growing forever
                if turns.count > 9 { turns = Array(turns.prefix(2)) + Array(turns.suffix(6)) }
            case .failure(let e):
                phase = .failed(e.localizedDescription)
            }
        }
    }

    /// The page part of a question. Kept identical to what BookMemory pre-reads.
    static func pageBlock(page: Int, current: String, previous: String) -> String {
        var user = ""
        let prev = String(previous.suffix(500))
        if !prev.isEmpty { user += "End of the previous page:\n…\(prev)\n\n" }
        user += "Current page (page \(page)):\n\(String(current.prefix(4000)))"
        return user
    }

    static func userPrompt(page: Int, current: String, previous: String, ask: Ask) -> String {
        let task: String
        switch ask {
        case .explain: task = "Explain what is happening on the current page in simple terms, using the story so far, and explain any hard words, names or references."
        case .summarize: task = "Summarize the current page in 3 to 5 short bullet points."
        case .words: task = "List the difficult, unusual or old-fashioned words and phrases on the current page, and explain each one simply in the context of the page."
        case .question(let q): task = "The reader asks: \(q)"
        }
        return pageBlock(page: page, current: current, previous: previous) + "\n\n" + task
    }

    /// Light Markdown: **bold**, *italic*, and bullet lines.
    static func render(_ s: String) -> AttributedString {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("* ") || t.hasPrefix("- ") {
                return "•  " + t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("#") { return "**" + t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**" }
            return line
        }
        let md = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    }
}
