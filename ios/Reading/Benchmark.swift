#if DEBUG
import Foundation
import PDFKit

/// Testing aid: launch with `-benchmark YES` to time book notes, an explanation
/// with the story so far, and a follow-up on the device. Results go to Documents/benchmark.txt.
@MainActor
enum Benchmark {
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func run(book: Book, bookURL: URL, page: Int) async {
        var log = "threads=\(LocalLLM.threadCount)/\(LocalLLM.batchThreadCount) gpu=\(LocalLLM.gpuUsable)\n"
        let out = Library.docs.appendingPathComponent("benchmark.txt")
        func flush() { try? log.write(to: out, atomically: true, encoding: .utf8) }
        flush()
        guard let doc = PDFDocument(url: bookURL) else { log += "no book\ndone\n"; flush(); return }

        // 1. Book notes
        let memory = BookMemory(book: book, doc: doc)
        let t0 = Date()
        memory.setPosition(page, immediately: true)
        await memory.waitIdle()
        log += String(format: "notes: %d pages read in %.0f s (memory %.0f MB)\n", memory.pagesRead, Date().timeIntervalSince(t0), memoryMB())
        log += memory.lastWarm + ", cached now \(await LocalLLM.shared.debugCachedCount)\n"
        log += "story so far for page \(page + 1):\n\(memory.context(before: page))\n"
        flush()

        // 2. Explain with context, then a follow-up
        let current = await PageText.text(of: doc, index: page)
        let previous = page > 0 ? await PageText.text(of: doc, index: page - 1) : ""
        let system = BookMemory.systemPrompt(title: book.title, kind: book.resolvedKind, context: memory.context(before: page))
        var turns = [Turn(role: "system", text: system),
                     Turn(role: "user", text: ExplainView.userPrompt(page: page + 1, current: current, previous: previous, ask: .explain))]
        for q in ["(explain)", "Who are the main people so far?"] {
            if q != "(explain)" { turns.append(Turn(role: "user", text: q)) }
            let collector = TextCollector()
            let send = turns
            do {
                let s = try await Task.detached { try await LocalLLM.shared.generate(turns: send, maxTokens: 300, stop: StopFlag()) { collector.append($0) } }.value
                log += String(format: "\n== %@: reused %d tok, read %d tok in %.1f s | wrote %d tok at %.1f tok/s | memory %.0f MB\n",
                              q, s.reusedTokens, s.promptTokens, s.promptSeconds, s.outputTokens, s.tokensPerSecond, memoryMB())
                log += collector.text + "\n"
                turns.append(Turn(role: "model", text: collector.text))
            } catch {
                log += "error: \(error.localizedDescription)\n"
            }
            flush()
        }
        log += "done\n"
        flush()
    }
}
#endif
