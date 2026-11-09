import SwiftUI
import UniformTypeIdentifiers

@main
struct ReadingApp: App {
    @State private var library = Library()
    @AppStorage("darkPages") private var darkPages = true

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .preferredColorScheme(darkPages ? .dark : .light)
        }
    }
}

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var showImporter = false
    @State private var openBook: Book?
    @State private var toRemove: Book?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 28, alignment: .bottom)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.books.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                        ForEach(library.books) { book in
                            BookCard(book: book, cover: library.coverURL(book))
                                .onTapGesture { open(book) }
                                .contextMenu {
                                    Button("Remove from Library", systemImage: "trash", role: .destructive) { toRemove = book }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                Text("Books and the AI stay on this device, so everything works offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: { Label("Add PDF", systemImage: "plus") }
                }
            }
            .background(Color(.systemBackground))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importURLs(urls)
        }
        .onOpenURL { url in importURLs([url]) }
        #if DEBUG
        .onAppear {
            // Testing aid: `-importPath /path/to/book.pdf` adds a book on launch.
            if let p = UserDefaults.standard.string(forKey: "importPath") {
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : Library.docs.appendingPathComponent(p)
                library.importPDF(from: url)
            }
            if UserDefaults.standard.bool(forKey: "benchmark"), let b = library.books.first {
                let url = library.fileURL(b)
                let page = max(1, UserDefaults.standard.integer(forKey: "benchPage") - 1)
                Task { await Benchmark.run(book: b, bookURL: url, page: page) }
            }
            if UserDefaults.standard.bool(forKey: "openFirst"), let b = library.books.first { open(b) }
        }
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            importURLs(pdfs)
            return !pdfs.isEmpty
        }
        .fullScreenCover(item: $openBook) { book in
            ReaderView(book: book)
        }
        .statusBarHidden(openBook != nil)
        .confirmationDialog("Remove “\(toRemove?.title ?? "")” from this device?", isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let b = toRemove { library.remove(b) } }
        }
        .alert("Couldn’t add that book", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var emptyState: some View {
        Button { showImporter = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "book").font(.system(size: 44, weight: .light))
                Text("Add a book").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("Tap to choose a PDF from Files, or share a PDF to Reading.")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 320)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .padding(24)
    }

    private func open(_ book: Book) {
        library.markOpened(book.id)
        openBook = library.books.first { $0.id == book.id }
    }

    private func importURLs(_ urls: [URL]) {
        var last: Book?
        for url in urls {
            if let b = library.importPDF(from: url) { last = b } else { error = "“\(url.lastPathComponent)” isn’t a readable PDF." }
        }
        if urls.count == 1, let last { open(last) }
    }
}

struct BookCard: View {
    let book: Book
    let cover: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let img = UIImage(contentsOfFile: cover.path) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).aspectRatio(2/3, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottom)

            if book.openedAt == nil {
                Text("NEW").font(.caption2.weight(.bold)).foregroundStyle(.blue)
            } else {
                HStack(spacing: 8) {
                    ProgressView(value: book.progress).tint(.primary)
                    Text("\(Int((book.progress * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(book.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
