import PDFKit
import SwiftUI

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let page: Int?      // 0-based
    let depth: Int
}

struct ReaderView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("darkPages") private var darkPages = true

    @State private var book: Book
    @State private var doc: PDFDocument?
    @State private var renderer: PageRenderer
    @State private var memory: BookMemory?
    @State private var aspect: CGFloat = 2.0 / 3.0

    @State private var spreadMode = false
    @State private var spreadIndex: Int?
    @State private var ready = false

    @State private var showUI = false
    @State private var showTOC = false
    @State private var showExplain = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    @State private var outline: [OutlineItem] = []
    @State private var chapters: [Int] = []
    @FocusState private var focused: Bool

    init(book: Book) {
        let url = Library.booksDir.appendingPathComponent(book.fileName)
        _book = State(initialValue: book)
        _doc = State(initialValue: PDFDocument(url: url))
        _renderer = State(initialValue: PageRenderer(url: url))
        if let d = PDFDocument(url: url) { _memory = State(initialValue: BookMemory(book: book, doc: d)) }
    }

    private var total: Int { book.pageCount }
    private var kind: BookKind { book.resolvedKind }
    private var rtl: Bool { kind.rightToLeft }
    private var artwork: Bool { kind != .novel }

    // Print-style spreads: cover alone, then [2,3], [4,5] … (1-based)
    private func spreads(_ two: Bool) -> [[Int]] {
        guard total > 0 else { return [] }
        if !two { return (0..<total).map { [$0] } }
        var out: [[Int]] = [[0]]
        var p = 1
        while p < total { out.append(p + 1 < total ? [p, p + 1] : [p]); p += 2 }
        return out
    }
    private func index(of page: Int, two: Bool) -> Int {
        two ? (page <= 0 ? 0 : (page - 1) / 2 + 1) : max(0, min(page, total - 1))
    }
    private var list: [[Int]] { spreads(spreadMode) }
    private var visible: [Int] {
        let l = list
        guard let i = spreadIndex, l.indices.contains(i) else { return [book.page] }
        return l[i]
    }

    var body: some View {
        GeometryReader { geo in
            let two = geo.size.width > geo.size.height * 1.05 && geo.size.width >= 700
            ZStack {
                Color(darkPages ? .black : UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1)).ignoresSafeArea()

                if ready {
                    pager(size: geo.size)
                }

                header
                footer
                if showUI { chrome.transition(.opacity) }
            }
            .onAppear {
                spreadMode = two
                spreadIndex = index(of: book.page, two: two)
                ready = true
                focused = true
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "showExplain") { showExplain = true }
                if UserDefaults.standard.bool(forKey: "showUI") { showUI = true }
                let sp = UserDefaults.standard.integer(forKey: "startPage")
                if sp > 0 { spreadIndex = index(of: sp - 1, two: two) }
                #endif
            }
            .onChange(of: two) { _, newValue in
                let page = visible.first ?? book.page
                spreadMode = newValue
                spreadIndex = index(of: page, two: newValue)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
        .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
        .onKeyPress(.space) { turn(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onChange(of: spreadIndex) { _, _ in
            saveProgress()
            memory?.setPosition(visible.first ?? 0)
        }
        .onAppear { memory?.setPosition(book.page) }
        .onDisappear { memory?.shutdown() }
        .task {
            aspect = await renderer.aspect(of: total > 2 ? 1 : 0)
            await loadOutline()
        }
        .sheet(isPresented: $showTOC) { tocSheet }
        .inspector(isPresented: $showExplain) {
            if let doc {
                ExplainView(title: book.title, kind: kind, doc: doc, pages: visible, memory: memory)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
            }
        }
        .preferredColorScheme(darkPages ? .dark : .light)
    }

    // MARK: Pages

    private func pager(size: CGSize) -> some View {
        CurlPager(total: total, two: spreadMode, rtl: rtl, compact: artwork, spread: $spreadIndex,
                  renderer: renderer, dark: darkPages, invert: kind.invertsInDarkMode, aspect: aspect) { x in
            tap(atFraction: rtl ? 1 - x : x)
        }
        .id("\(spreadMode)-\(kind.rawValue)") // spine and direction are fixed when the pager is created
            .ignoresSafeArea()
    }

    private func tap(atFraction x: CGFloat) {
        if showUI { withAnimation(.easeOut(duration: 0.2)) { showUI = false }; return }
        if x < 0.28 { turn(-1) }
        else if x > 0.72 { turn(1) }
        else { withAnimation(.easeOut(duration: 0.2)) { showUI = true } }
    }

    private func turn(_ dir: Int) {
        guard let i = spreadIndex else { return }
        let next = i + dir
        guard list.indices.contains(next) else { return }
        spreadIndex = next   // CurlPager animates the page curl
    }

    private func jump(toPage page: Int) {
        let i = index(of: page, two: spreadMode)
        spreadIndex = i
    }

    private func saveProgress() {
        let v = visible
        book.page = v.first ?? 0
        book.lastSeen = v.last ?? 0
        book.openedAt = Date()
        library.update(book)
        if !scrubbing { scrub = Double(book.page) }
    }

    private func close() {
        saveProgress()
        memory?.shutdown()
        dismiss()
    }

    private func setKind(_ k: BookKind) {
        book.kind = k
        library.update(book)
        memory?.kind = k
        Task { await renderer.clear() }
    }

    // MARK: Overlays

    private var header: some View {
        VStack {
            Text(book.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 90)
                .padding(.top, 14)
                .opacity(showUI || artwork ? 0 : 1)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer()
                Text(artwork ? "" : pagesLeftText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 28)
                    .padding(.bottom, 16)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.primary.opacity(0.1))
                    Rectangle().fill(.secondary)
                        .frame(width: g.size.width * CGFloat((visible.last ?? 0) + 1) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 2)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    private var pagesLeftText: String {
        let last = visible.last ?? 0
        if !chapters.isEmpty {
            let next = chapters.first { $0 > last }
            let left = (next ?? total) - last - 1
            guard left > 0 else { return "" }
            return "\(left) page\(left == 1 ? "" : "s") left in \(next == nil ? "book" : "chapter")"
        }
        let left = total - last - 1
        return left > 0 ? "\(left) page\(left == 1 ? "" : "s") left" : ""
    }

    private var chrome: some View {
        VStack {
            HStack {
                GlassGroup {
                    Button { close() } label: { Image(systemName: "square.grid.2x2") }
                        .accessibilityLabel("Library")
                    Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Contents")
                }
                Spacer()
                GlassGroup {
                    Menu {
                        Picker("Type", selection: Binding(get: { kind }, set: setKind)) {
                            ForEach(BookKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel("Book type")
                    Button { showExplain.toggle() } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Explain")
                    Button {
                        darkPages.toggle()
                        Task { await renderer.clear() }
                    } label: { Image(systemName: "circle.lefthalf.filled") }
                        .accessibilityLabel("Dark or light pages")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Spacer()

            HStack(spacing: 14) {
                Slider(value: $scrub, in: 0...Double(max(total - 1, 1)), step: 1) { editing in
                    scrubbing = editing
                    if !editing { jump(toPage: Int(scrub)) }
                }
                .tint(.primary)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                Text(scrubLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 560)
            .padding(.bottom, 14)
            .padding(.horizontal, 16)
        }
    }

    private var scrubLabel: String {
        let pages = scrubbing ? list[index(of: Int(scrub), two: spreadMode)] : visible
        let s = pages.map { "\($0 + 1)" }.joined(separator: "–")
        return "\(s) of \(total)"
    }

    // MARK: Contents

    private var tocSheet: some View {
        NavigationStack {
            Group {
                if outline.isEmpty {
                    ContentUnavailableView("No table of contents", systemImage: "list.bullet",
                                           description: Text("This PDF doesn’t include one. Use the slider to jump around."))
                } else {
                    ScrollViewReader { proxy in
                        List(outline) { item in
                            Button {
                                showTOC = false
                                if let p = item.page { jump(toPage: p) }
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.title)
                                        .foregroundStyle(item.id == currentOutlineID ? Color.accentColor : (item.depth == 0 ? .primary : .secondary))
                                        .fontWeight(item.id == currentOutlineID ? .semibold : .regular)
                                    Spacer()
                                    if let p = item.page { Text("\(p + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                                }
                                .padding(.leading, CGFloat(item.depth) * 16)
                            }
                            .id(item.id)
                        }
                        .listStyle(.plain)
                        .onAppear { if let id = currentOutlineID { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTOC = false } } }
        }
        .presentationDetents([.large])
    }

    private var currentOutlineID: UUID? {
        let last = visible.last ?? 0
        return outline.last { ($0.page ?? .max) <= last }?.id
    }

    private func loadOutline() async {
        guard let doc, let root = doc.outlineRoot else { return }
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                var page: Int?
                if let p = child.destination?.page { page = doc.index(for: p) }
                else if let action = child.action as? PDFActionGoTo, let p = action.destination.page { page = doc.index(for: p) }
                items.append(OutlineItem(title: (child.label ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines), page: page, depth: depth))
                if depth < 2 { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        outline = items
        let withPage = items.filter { $0.page != nil }
        let top = withPage.filter { $0.depth == 0 }
        let src = top.count >= 3 ? top : withPage
        chapters = Array(Set(src.compactMap(\.page))).sorted()
    }
}

/// A small frosted pill of toolbar buttons, like Apple Books.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .buttonStyle(ChromeButtonStyle())
            .padding(3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 34)
            .background(configuration.isPressed ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }
}
