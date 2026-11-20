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
    @AppStorage("reflow") private var reflowOn = true          // fit the text to the screen, like Kindle
    @AppStorage("textSize") private var textSize: Double = 23

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

    @State private var source: ReflowSource?
    @State private var layout: ReflowLayout?
    @State private var preparing: Double?      // progress reading a scanned book's text (0…1)
    @State private var anchor = 0              // character offset of the first page on screen (reflowed text)

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

    /// Pages in the current layout: reflowed screens of text, or the PDF's pages.
    private var total: Int { activeLayout?.pageCount ?? book.pageCount }
    private var wantsReflow: Bool { reflowOn && kind == .novel }
    private var reflowing: Bool { wantsReflow && source?.hasText == true }
    private var activeLayout: ReflowLayout? { reflowing ? layout : nil }

    /// PDF pages on screen (the Explain panel, reading memory and saved progress use these).
    private var visiblePDF: [Int] {
        let v = visible
        guard let l = activeLayout, let f = v.first, let e = v.last else { return v }
        let a = l.firstPDFPage(ofPage: f), b = l.lastPDFPage(ofPage: e)
        return Array(a...max(a, b))
    }
    private func displayPage(forPDF p: Int) -> Int { activeLayout?.page(forPDFPage: p) ?? p }
    private var kind: BookKind { book.resolvedKind }
    private var rtl: Bool { kind.rightToLeft }
    private var artwork: Bool { kind != .novel }

    // Print-style spreads: cover alone, then [2,3], [4,5] … (1-based)
    private func spreads(_ two: Bool) -> [[Int]] {
        guard total > 0 else { return [] }
        if !two { return (0..<total).map { [$0] } }
        if activeLayout != nil {   // flowing text: [1,2], [3,4] …
            return stride(from: 0, to: total, by: 2).map { $0 + 1 < total ? [$0, $0 + 1] : [$0] }
        }
        var out: [[Int]] = [[0]]
        var p = 1
        while p < total { out.append(p + 1 < total ? [p, p + 1] : [p]); p += 2 }
        return out
    }
    private func index(of page: Int, two: Bool) -> Int {
        let page = max(0, min(page, total - 1))
        if two && activeLayout != nil { return page / 2 }
        return two ? (page <= 0 ? 0 : (page - 1) / 2 + 1) : page
    }
    private var list: [[Int]] { spreads(spreadMode) }
    private var visible: [Int] {
        let l = list
        guard let i = spreadIndex, l.indices.contains(i) else { return [book.page] }
        return l[i]
    }

    var body: some View {
        GeometryReader { geo in
            let fold = Self.verticalFold(geo)
            // On a foldable (iPhone Duo) the fold becomes the spine of the book.
            let two = fold != nil || (geo.size.width > geo.size.height * 1.05 && geo.size.width >= 700)
            let spec = reflowing ? reflowSpec(geo, two: two, fold: fold) : nil
            ZStack {
                Color(darkPages ? .black : UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1)).ignoresSafeArea()

                if ready && !waiting(spec) {
                    pager(size: geo.size, spineGap: fold.map { $0.width / 2 })
                } else if ready {
                    ProgressView().controlSize(.large)
                }

                header
                footer
                if let p = preparing { preparingPill(p) }
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
            .task(id: spec?.key) {
                guard let spec, let source else { return }
                let l = await Task.detached(priority: .userInitiated) {
                    ReflowLayout(source: source, key: spec.key, size: spec.size, rects: spec.rects)
                }.value
                guard !Task.isCancelled else { return }
                layout = l
                spreadIndex = index(of: l.page(forOffset: anchor), two: spreadMode)
            }
            .onChange(of: two) { _, newValue in
                let page = visible.first ?? book.page
                spreadMode = newValue
                spreadIndex = index(of: page, two: newValue)
            }
            .onChange(of: reflowing) { _, on in
                // Switching between fitted text and original pages keeps your place.
                if on, let source {
                    if let o = book.textOffset, source.pdfPage(forOffset: o) == book.page { anchor = o }
                    else { anchor = source.offset(forPDFPage: book.page) }
                } else {
                    layout = nil
                    spreadIndex = index(of: book.page, two: spreadMode)
                }
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
            memory?.setPosition(visiblePDF.first ?? 0)
        }
        .onAppear { memory?.setPosition(book.page) }
        .onDisappear { memory?.shutdown() }
        .task {
            aspect = await renderer.aspect(of: book.pageCount > 2 ? 1 : 0)
            await loadOutline()
        }
        .task(id: wantsReflow) {
            guard wantsReflow, source == nil else { return }
            let s = await ReflowSource.load(bookID: book.id, url: library.fileURL(book), title: book.title) { p in
                Task { @MainActor in if p < 1, source == nil { preparing = max(preparing ?? 0, p) } }
            }
            preparing = nil
            // Pick up where you left off: the saved text position if it still matches the saved page.
            source = s   // the change of `reflowing` sets the starting position
        }
        .sheet(isPresented: $showTOC) { tocSheet }
        .inspector(isPresented: $showExplain) {
            if let doc {
                ExplainView(title: book.title, kind: kind, doc: doc, pages: visiblePDF, memory: memory)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                    // On a phone this is a sheet: open halfway so the page stays in view.
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .preferredColorScheme(darkPages ? .dark : .light)
    }

    // MARK: Pages

    /// The fold of a foldable iPhone when it runs top to bottom down the middle of
    /// the screen (the phone held open like a book). Nil on other devices.
    static func verticalFold(_ geo: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let w = geo.size.width
        return geo.reservedRegions(kind: .division)
            .filter { $0.isActive }
            .map(\.frame)
            .first { $0.height > $0.width && $0.height >= geo.size.height * 0.8 && abs($0.midX - w / 2) < w * 0.05 }
    }

    /// True while the reflowed text is still being prepared for this screen.
    private func waiting(_ spec: ReflowSpec?) -> Bool {
        guard wantsReflow else { return false }
        guard let source else { return false }   // read the original pages meanwhile
        guard source.hasText, let spec else { return false }
        return layout?.key != spec.key
    }

    struct ReflowSpec {
        var key: ReflowLayout.Key
        var size: CGSize
        var rects: [PageSlotController.Side: CGRect]
    }

    /// The text box on each page: the whole screen minus margins, with the
    /// fold (or the middle of a landscape screen) as the gap between columns.
    private func reflowSpec(_ geo: GeometryProxy, two: Bool, fold: CGRect?) -> ReflowSpec {
        let ins0 = geo.safeAreaInsets
        let full = CGSize(width: geo.size.width + ins0.leading + ins0.trailing,
                          height: geo.size.height + ins0.top + ins0.bottom)
        // The status bar is hidden, so its strip (the side of the Duo's outer
        // screen) is free for text, like the rest of the reader.
        let ins = EdgeInsets(top: ins0.top, leading: 0, bottom: ins0.bottom, trailing: 0)
        let outer: CGFloat = full.width >= 700 ? 48 : 22
        let top = ins.top + 50
        let h = (full.height - top - ins.bottom - 50).rounded(.down)
        var rects: [PageSlotController.Side: CGRect] = [:]
        let w: CGFloat
        if two {
            let slotW = (full.width / 2).rounded(.down)
            let inner = max((fold?.width ?? 0) / 2 + 20, 28)
            w = (slotW - outer - max(ins.leading, ins.trailing) - inner).rounded(.down)
            rects[.left] = CGRect(x: slotW - inner - w, y: top, width: w, height: h)
            rects[.right] = CGRect(x: inner, y: top, width: w, height: h)
        } else {
            let avail = full.width - outer * 2 - ins.leading - ins.trailing
            w = min(avail, CGFloat(textSize) * 34).rounded(.down)    // keep lines a comfortable length
            rects[.single] = CGRect(x: (ins.leading + outer + (avail - w) / 2).rounded(), y: top, width: w, height: h)
        }
        let size = CGSize(width: max(w, 50), height: max(h, 50))
        return ReflowSpec(key: .init(book: book.id, width: Int(size.width), height: Int(size.height), fontSize: textSize),
                          size: size, rects: rects)
    }

    private func pager(size: CGSize, spineGap: CGFloat?) -> some View {
        CurlPager(total: total, two: spreadMode, rtl: rtl, compact: artwork, spineGap: spreadMode ? spineGap : nil,
                  reflow: activeLayout,
                  spread: $spreadIndex,
                  renderer: renderer, dark: darkPages, invert: kind.invertsInDarkMode, aspect: aspect) { x in
            tap(atFraction: rtl ? 1 - x : x)
        }
        // spine, gap, direction and text layout are fixed when the pager is created
        .id("\(spreadMode)-\(kind.rawValue)-\(Int(spineGap ?? -1))-\(activeLayout.map { "\($0.key)" } ?? "pdf")")
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
        let v = visiblePDF
        book.page = v.first ?? 0
        book.lastSeen = v.last ?? 0
        if let l = activeLayout, let first = visible.first {
            anchor = l.offset(ofPage: first)
            book.textOffset = anchor
        }
        book.openedAt = Date()
        library.update(book)
        if !scrubbing { scrub = Double(visible.first ?? 0) }
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

    /// Shown the first time a scanned book is opened, while its words are read off the pages.
    private func preparingPill(_ p: Double) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Making the text bigger… \(Int(p * 100))%").font(.footnote).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 44)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var header: some View {
        VStack {
            Text(book.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 90)
                .padding(.top, 14)
                .textCase(reflowing ? .uppercase : nil)
                .opacity(showUI || artwork ? 0 : 1)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .horizontal)   // the status bar is hidden, so use its space
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
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        .allowsHitTesting(false)
    }

    private var pagesLeftText: String {
        let last = visible.last ?? 0
        if !chapters.isEmpty {
            let starts = chapters.map(displayPage(forPDF:))
            let next = starts.first { $0 > last }
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
                        if kind == .novel {
                            if reflowing {
                                ControlGroup {
                                    Button { textSize = max(14, textSize - 2) } label: {
                                        Label("Smaller", systemImage: "textformat.size.smaller")
                                    }
                                    .disabled(textSize <= 14)
                                    Button { textSize = min(40, textSize + 2) } label: {
                                        Label("Larger", systemImage: "textformat.size.larger")
                                    }
                                    .disabled(textSize >= 40)
                                }
                                .menuActionDismissBehavior(.disabled)
                            }
                            Picker("Layout", selection: $reflowOn) {
                                Label("Fit text to screen", systemImage: "text.alignleft").tag(true)
                                Label("Original pages", systemImage: "doc.richtext").tag(false)
                            }
                        }
                        Picker("Type", selection: Binding(get: { kind }, set: setKind)) {
                            ForEach(BookKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel("Text and layout")
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
        .ignoresSafeArea(edges: .horizontal)
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
                                if let p = item.page { jump(toPage: displayPage(forPDF: p)) }
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.title)
                                        .foregroundStyle(item.id == currentOutlineID ? Color.accentColor : (item.depth == 0 ? .primary : .secondary))
                                        .fontWeight(item.id == currentOutlineID ? .semibold : .regular)
                                    Spacer()
                                    if let p = item.page { Text("\(displayPage(forPDF: p) + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
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
        let last = visiblePDF.last ?? 0
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
